import Foundation
import MochiKernel

public enum TranscriptionState: String, Codable { case pending, completed, failed, timedOut, interrupted }
public struct HelpDraft: Codable {
    public var meaning: String
    public var english: String
    public var recording: String?
    public var expressionID: UUID?
    public var clarification: String?
    public var transcriptReview: String?
    public init(meaning: String = "", english: String = "", recording: String? = nil, expressionID: UUID? = nil) {
        self.meaning = meaning
        self.english = english
        self.recording = recording
        self.expressionID = expressionID
    }
}
public struct HelpSuggestion: Decodable {
    public enum Kind: String, Decodable { case expression, clarification }
    public let kind: Kind
    public let text: String
    public static func parse(_ text: String) throws -> HelpSuggestion {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
            !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AppFailure(
                "The English suggestion could not be read. Try again; your thought and previous wording are kept.")
        }
        return value
    }
}
public struct RecordingSignal {
    public let rmsDB: Double
    public var isQuiet: Bool { rmsDB < -48 }
    public init(samples: [Float]) {
        let finite = samples.map { $0.isFinite ? Double($0) : 0 }
        let rms = sqrt(finite.reduce(0) { $0 + $1 * $1 } / Double(max(1, finite.count)))
        rmsDB = 20 * log10(max(rms, 1e-9))
    }
}
struct RealtimeTimeout: Error {}
/// Cancelling or expiring a deadline closes the transport to unblock a suspended receive.
/// Completion and expiry are arbitrated under one lock: whichever settles first wins, so a deadline
/// that fires after the operation finished never closes a transport that is still in use.
final class RealtimeDeadline: @unchecked Sendable {
    private enum Outcome { case running, finished, expired }
    private let lock = NSLock()
    private var outcome = Outcome.running
    /// True when this call expired the deadline; false when the operation had already finished.
    private func expire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running else { return false }
        outcome = .expired
        return true
    }
    /// True when the operation finished in time; false when the deadline had already expired.
    private func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running else { return outcome == .finished }
        outcome = .finished
        return true
    }
    static func run<T>(
        nanoseconds: UInt64, close: @escaping @Sendable () -> Void,
        operation: () async throws -> T
    ) async throws -> T {
        let state = RealtimeDeadline()
        let timer = Task {
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            guard !Task.isCancelled, state.expire() else { return }
            close()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler(
            operation: {
                do {
                    try Task.checkCancellation()
                    let result = try await operation()
                    guard state.finish() else { throw RealtimeTimeout() }
                    try Task.checkCancellation()
                    return result
                } catch {
                    let inTime = state.finish()
                    if Task.isCancelled { throw CancellationError() }
                    if !inTime { throw RealtimeTimeout() }
                    throw error
                }
            }, onCancel: close)
    }
}
struct RealtimeChannel {
    let send: ([String: Any]) async throws -> Void
    let receive: () async throws -> [String: Any]
    let close: @Sendable () -> Void
    static func live(_ request: URLRequest) -> RealtimeChannel {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4_000_000
        socket.resume()
        return RealtimeChannel(
            send: { event in
                let bytes = try JSONSerialization.data(withJSONObject: event)
                try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
            },
            receive: {
                let message = try await socket.receive()
                let bytes: Data
                switch message {
                case .data(let data): bytes = data
                case .string(let text): bytes = Data(text.utf8)
                @unknown default: throw AppFailure("Unexpected Realtime response.")
                }
                guard let event = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw AppFailure("Invalid Realtime event.")
                }
                return event
            },
            close: {
                socket.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            })
    }
}
extension RealtimeService {
    /// Transcribes one retained recording using the selected Realtime connection.
    /// With VAD disabled, commit starts transcription; no response.create is sent.
    public func transcribe(_ pcm: Data) async throws -> String {
        try await transcribe(pcm, credential: { try await token() }, connect: RealtimeChannel.live)
    }
    /// Full transport lifecycle seam: request construction, deadlines and cancellation.
    func transcribe(
        _ pcm: Data, credential: () async throws -> String,
        connect: (URLRequest) -> RealtimeChannel,
        timeoutNanoseconds: UInt64 = 60_000_000_000
    ) async throws -> String {
        try Self.validateTranscriptionAudio(pcm)
        try Task.checkCancellation()
        let token = try await credential()
        try Task.checkCancellation()
        let channel = connect(realtimeRequest(token: token))
        defer { channel.close() }
        do {
            return try await RealtimeDeadline.run(nanoseconds: timeoutNanoseconds, close: channel.close) {
                try await Self.transcribeTurn(pcm, send: channel.send, receive: channel.receive)
            }
        } catch is CancellationError { throw CancellationError() } catch is RealtimeTimeout {
            throw AppFailure("Transcription timed out. Your recording is saved; retry or add text.")
        } catch let error as AppFailure { throw error } catch let error as URLError {
            throw AppFailure(
                ServiceHTTP.transportFailure(error, provider: "OpenAI").message + " Your recording is saved.",
                underlying: error)
        } catch {
            throw AppFailure(
                "The transcription connection ended. Your recording is saved; check your connection and retry, or add text.",
                underlying: error)
        }
    }
    /// 16-bit mono 24 kHz PCM from a moment (0.1 s) up to 65 seconds long.
    static func isRecordedAudio(_ pcm: Data) -> Bool {
        pcm.count >= 4800 && pcm.count <= 65 * 48000 && pcm.count.isMultiple(of: 2)
    }
    private static func validateTranscriptionAudio(_ pcm: Data) throws {
        guard isRecordedAudio(pcm) else {
            throw AppFailure("Choose a recording between a moment and 65 seconds long to transcribe.")
        }
    }
    /// Same event path for real WebSockets and deterministic transport tests.
    static func transcribeTurn(
        _ pcm: Data, send: ([String: Any]) async throws -> Void,
        receive: () async throws -> [String: Any]
    ) async throws -> String {
        try validateTranscriptionAudio(pcm)
        var accumulator = RealtimeAccumulator()
        func waitFor(_ type: String) async throws {
            while true {
                try Task.checkCancellation()
                let event = try await receive()
                try Task.checkCancellation()
                try accumulator.accept(event)
                if event["type"] as? String == type { return }
            }
        }
        try await waitFor("session.created")
        try await send([
            "type": "session.update",
            "session": [
                "type": "realtime", "output_modalities": ["text"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000], "turn_detection": NSNull(),
                        "transcription": ["model": RealtimeService.transcriptionModel],
                    ]
                ],
            ],
        ])
        try await waitFor("session.updated")
        for offset in stride(from: 0, to: pcm.count, by: 48000) {
            try Task.checkCancellation()
            try await send([
                "type": "input_audio_buffer.append",
                "audio": pcm.subdata(in: offset..<min(offset + 48000, pcm.count)).base64EncodedString(),
            ])
        }
        try Task.checkCancellation()
        try await send(["type": "input_audio_buffer.commit"])
        while accumulator.transcriptionState == .pending {
            try Task.checkCancellation()
            let event = try await receive()
            try Task.checkCancellation()
            // The accumulator ignores transcript events that do not match this commit's item.
            try accumulator.accept(event)
        }
        try Task.checkCancellation()
        guard accumulator.transcriptionState == .completed else {
            throw AppFailure(
                accumulator.transcriptionError ?? "Transcription failed. Your recording is saved; retry or add text.")
        }
        return accumulator.inputTranscript
    }
}
