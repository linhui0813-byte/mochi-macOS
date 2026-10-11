import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

/// Never answers, so a request stays in flight until the task is cancelled.
private final class SilentProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

final class AuditFixG2Tests: XCTestCase {
    private func tone(_ hz: Double, rate: Double = 24000, count: Int = 24000) -> [Float] {
        (0..<count).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / rate)) }
    }
    private func medianPitch(_ hz: Double, rate: Double = 24000) -> Double {
        let values = PitchAnalyzer.analyze(samples: tone(hz, rate: rate, count: Int(rate)), sampleRate: rate)
            .compactMap(\.hz).sorted()
        return values.isEmpty ? 0 : values[values.count / 2]
    }

    // MARK: Pitch

    func testUnrepresentableSampleRatesReturnNoPitchInsteadOfTrapping() {
        XCTAssertTrue(PitchAnalyzer.analyze(samples: tone(200), sampleRate: .infinity).isEmpty)
        XCTAssertTrue(PitchAnalyzer.analyze(samples: tone(200), sampleRate: 1e300).isEmpty)
        XCTAssertTrue(PitchAnalyzer.analyze(samples: tone(200), sampleRate: .nan).isEmpty)
    }
    func testTonesNearNyquistDoNotAliasIntoSpeechPitch() {
        XCTAssertTrue(PitchAnalyzer.analyze(samples: tone(11800), sampleRate: 24000).allSatisfy { $0.hz == nil })
        XCTAssertTrue(
            PitchAnalyzer.analyze(samples: tone(23800, rate: 48000, count: 48000), sampleRate: 48000)
                .allSatisfy { $0.hz == nil })
    }
    func testPitchAtBothEndsOfTheRangeIsFound() {
        XCTAssertEqual(medianPitch(65), 65, accuracy: 1)
        XCTAssertEqual(medianPitch(495), 495, accuracy: 3)
        XCTAssertEqual(medianPitch(500, rate: 48000), 500, accuracy: 3)
    }
    func testAnExactlyOneWindowSignalAndShortLowRateClipsAreAnalysed() {
        XCTAssertEqual(PitchAnalyzer.analyze(samples: tone(200, count: 1080), sampleRate: 24000).count, 1)
        let short = PitchAnalyzer.analyze(samples: tone(200, rate: 8000, count: 400), sampleRate: 8000)
        XCTAssertEqual(short.compactMap(\.hz).first ?? 0, 200, accuracy: 2)
    }

    // MARK: Voices

    func testCanonicallyEquivalentTextMatches() {
        XCTAssertTrue(ReferenceSpeech.matches("Un café, s'il vous plaît.", "Un cafe\u{0301}, s'il vous plai\u{0302}t!"))
        XCTAssertFalse(ReferenceSpeech.matches("café", "cafe"))
    }
    func testNonFiniteSpeedStillNamesTheCacheWithoutCrashing() {
        var nan = OpenAIVoiceOptions()
        nan.speed = .nan
        var infinite = OpenAIVoiceOptions()
        infinite.speed = .infinity
        let a = ReferenceSpeech.cacheName(text: "Hi", model: "m", voice: "marin", options: nan)
        let b = ReferenceSpeech.cacheName(text: "Hi", model: "m", voice: "marin", options: infinite)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, ReferenceSpeech.cacheName(text: "Hi", model: "m", voice: "marin"))
    }

    // MARK: Voice identity

    func testCustomCharacterInstructionsDropTheMochiIdentityLines() {
        let legacy = VoiceIdentity.instructions
            .replacingOccurrences(of: "You are Mochi (pronounced MOH-chee),", with: "You are")
            .replacingOccurrences(of: "Your name is Mochi. ", with: "")
            .replacingOccurrences(of: "A mention of Mochi", with: "A mention of your name")
        let custom = VoiceIdentity.conversationInstructions(
            custom: "", preferences: ConversationPreferences(), characterName: "Loki")
        XCTAssertTrue(custom.contains(legacy))
        XCTAssertFalse(legacy.contains("Mochi"))
        let mochi = VoiceIdentity.conversationInstructions(
            custom: "", preferences: ConversationPreferences(), characterName: "Mochi")
        XCTAssertTrue(mochi.contains(VoiceIdentity.instructions))
    }
    func testNamedGreetingNeverRepeatsTheLastThree() {
        var recent: [String] = []
        for _ in 0..<60 {
            let greeting = VoiceIdentity.namedGreeting(name: "Loki", excluding: recent)
            XCTAssertFalse(recent.suffix(3).contains(greeting.pattern))
            recent.append(greeting.pattern)
        }
    }

    // MARK: Providers

    func testDamagedAudioDeltaIsRejected() {
        var reply = RealtimeAccumulator()
        XCTAssertThrowsError(try reply.accept(["type": "response.output_audio.delta", "delta": "not base64!"]))
        XCTAssertThrowsError(try reply.accept(["type": "response.output_audio.delta"]))
        XCTAssertTrue(reply.audio.isEmpty)
    }
    func testTruncatedReferenceAudioIsNotCached() async throws {
        let root = TestScratch.folder("g2-reference")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var result = RealtimeAccumulator()
        result.text = "Hello there."
        result.audio = Data(repeating: 1, count: 4800)
        result.truncated = true
        let cut = result
        do {
            _ = try await RealtimeService().referenceAudio(text: "Hello there.", root: root, force: true) { _ in cut }
            XCTFail("A truncated example was accepted")
        } catch {
            XCTAssertTrue(error is AppFailure)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testInvalidVoiceMessageAudioIsRejectedBeforeSigningIn() async {
        for pcm in [Data(), Data(count: 4799), Data(count: 4801), Data(count: 65 * 48000 + 2)] {
            var signedIn = false
            do {
                _ = try await RealtimeService().reply(
                    ConversationRequest(history: [], text: "", pcm: pcm, spoken: true),
                    credential: {
                        signedIn = true
                        return "session"
                    },
                    connect: { _ in
                        XCTFail("connected")
                        return RealtimeChannel(send: { _ in }, receive: { [:] }, close: {})
                    })
                XCTFail("Accepted \(pcm.count) bytes")
            } catch {
                XCTAssertTrue(error is AppFailure)
            }
            XCTAssertFalse(signedIn)
        }
    }
    @MainActor func testUnfinishedToolCallsAreAnsweredWithoutRunning() async throws {
        func call(_ id: String, status: String?) -> [String: Any] {
            var item: [String: Any] = [
                "type": "function_call", "call_id": id, "name": "get_session", "arguments": "{}",
            ]
            item["status"] = status
            return item
        }
        var events: [[String: Any]] = [
            [
                "type": "response.done",
                "response": [
                    "status": "incomplete", "status_details": ["reason": "max_output_tokens"],
                    "output": [
                        call("done", status: "completed"), call("cut", status: "incomplete"), call("bare", status: nil),
                    ],
                ],
            ],
            ["type": "response.output_text.delta", "delta": "Ok."],
            ["type": "response.done", "response": ["status": "completed"]],
        ]
        var ran: [String] = []
        var sent: [[String: Any]] = []
        _ = try await RealtimeService.deliverResponse(
            RealtimeAccumulator(), receive: { events.removeFirst() }, onResponse: nil, onTranscription: nil,
            onTool: { _, _, id in
                ran.append(id)
                return ["ok": true]
            }, send: { sent.append($0) })
        XCTAssertEqual(ran, ["done"])
        let answered = sent.compactMap { ($0["item"] as? [String: Any])?["call_id"] as? String }
        XCTAssertEqual(answered, ["done", "cut", "bare"])
    }
    func testCancelledHTTPRequestThrowsCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentProtocol.self]
        let request = URLRequest(url: URL(string: "https://example.invalid/never")!)
        let task = Task { try await ServiceHTTP.data(request, provider: "OpenAI", configuration: configuration) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled request returned data")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
    func testSignInPathThatIsAFIFOIsRejectedWithoutBlocking() throws {
        let folder = TestScratch.folder("g2-fifo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("auth.json")
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try Credentials.token(in: file, now: Date())) {
            XCTAssertEqual($0 as? Credentials.SignIn, .notOwned)
        }
        let regular = folder.appendingPathComponent("regular.json")
        try Data(#"{"tokens":{"access_token":"opaque"}}"#.utf8).write(to: regular)
        XCTAssertEqual(try Credentials.token(in: regular, now: Date()), "opaque")
        try Data(count: Credentials.maximumFileSize).write(to: regular)
        XCTAssertThrowsError(try Credentials.token(in: regular, now: Date())) {
            XCTAssertEqual($0 as? Credentials.SignIn, .unreadable)
        }
    }

}
