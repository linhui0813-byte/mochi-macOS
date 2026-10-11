import AVFoundation
import MochiCore
import MochiTestSupport
import XCTest

@testable import MochiApp

final class AuditFixR2ATests: XCTestCase {
    private func wav(rate: Double, frames: Int, _ sample: (Int) -> Float) throws -> URL {
        let folder = TestScratch.folder("r2a-audio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("clip-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = sample(i) }
        try file.write(from: buffer)
        return url
    }
    private func tone() -> Data {
        var pcm = Data()
        for i in 0..<12000 {
            var value = Int16(sin(2 * Double.pi * 180 * Double(i) / 24000) * 12000).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        return PCM.wav(pcm)
    }

    /// A take whose recorder stopped on its own; `finished` and `interrupted` model the recorder's late report.
    @MainActor private func stoppedTake(
        finished: @escaping () -> Bool, interrupted: @escaping () -> Bool = { false }
    ) async -> (AppModel, URL) {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        var recorded: URL?
        var active = true
        app.media.permission = { true }
        app.media.record = { url in
            recorded = url
            try self.tone().write(to: url)
        }
        app.media.stopRecording = { recorded }
        app.media.recordingActive = { active }
        app.media.recordingFinished = finished
        app.media.recordingInterrupted = interrupted
        app.recordingSleep = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        app.startHelp()
        app.recordMeaning()
        await waitUntil { app.turn.activity == .recording }
        active = false
        return (app, recorded!)
    }

    // MARK: #2, #18 — a stopped take is judged by the recorder's confirmed outcome, not elapsed time

    @MainActor func testStoppedTakeIsKeptOnceTheRecorderConfirmsSuccess() async throws {
        var finished = false
        let (app, url) = await stoppedTake(finished: { finished })
        app.finishRecording()
        // The outcome has not arrived yet: nothing is decided.
        XCTAssertNil(app.error)
        XCTAssertEqual(app.turn.activity, .recording)
        finished = true
        await waitUntil { app.thoughtRecording != nil && !app.busy }
        XCTAssertNil(app.error)
        XCTAssertEqual(app.thoughtRecording, url.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        app.stop()
    }
    @MainActor func testStoppedTakeIsDiscardedWhenAFailureArrivesLate() async throws {
        var interrupted = false
        let (app, url) = await stoppedTake(finished: { false }, interrupted: { interrupted })
        app.finishRecording()
        XCTAssertNil(app.error)
        interrupted = true
        await waitUntil { app.error != nil }
        XCTAssertTrue(app.error?.contains("microphone disconnected") == true, app.error ?? "no error")
        XCTAssertNil(app.thoughtRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    @MainActor func testStoppedTakeWithoutAConfirmedOutcomeIsDiscardedEvenNearTheLimit() async throws {
        var now = Date()
        let (app, url) = await stoppedTake(finished: { false })
        app.recordingNow = { now }
        now = now.addingTimeInterval(59.9)
        app.finishRecording()
        await waitUntil { app.error != nil }
        XCTAssertTrue(app.error?.contains("microphone disconnected") == true, app.error ?? "no error")
        XCTAssertNil(app.thoughtRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: #25 — resampling to 24 kHz is band-limited

    func testHighToneAbove12kHzDoesNotFoldIntoTheConvertedMessage() throws {
        for rate in [48000.0, 44100] {
            let url = try wav(rate: rate, frames: Int(rate)) {
                Float(0.5 * sin(2 * Double.pi * 16000 * Double($0) / rate))
            }
            let pcm = try AudioFile.pcm(url)
            XCTAssertEqual(pcm.count, 24000 * 2)
            let peak = pcm.withUnsafeBytes { raw in
                (100..<23900).map {
                    abs(Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))))
                }
                .max() ?? 0
            }
            // Sample skipping or linear interpolation leaves an 8 kHz (or 7.9 kHz) tone near full scale.
            XCTAssertLessThan(peak, 33, "rate \(rate)")
        }
    }

    // MARK: #26 — synchronous decoding honours the calling task's cancellation

    func testCancelledSynchronousDecodingThrowsInsteadOfReturningAResult() async throws {
        let url = try wav(rate: 24000, frames: 24000 * 5) { Float(0.5 * sin(2 * Double.pi * 200 * Double($0) / 24000)) }
        let outcomes = await Task.detached { () -> [String] in
            withUnsafeCurrentTask { $0?.cancel() }
            func outcome(_ work: () throws -> Any) -> String {
                do {
                    _ = try work()
                    return "returned"
                } catch is CancellationError { return "cancelled" } catch { return "\(error)" }
            }
            return [
                outcome { try AudioFile.samples(url) }, outcome { try AudioFile.pcm(url) },
                outcome { try AudioFile.pitch(url) },
            ]
        }.value
        XCTAssertEqual(outcomes, ["cancelled", "cancelled", "cancelled"])
    }
}
