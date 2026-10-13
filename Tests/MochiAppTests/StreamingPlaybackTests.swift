import MochiCore
import XCTest

@testable import MochiApp
@testable import MochiProviders

@MainActor private final class StreamPlayerFixture: StreamingPlaybackPlayer {
    var duration: TimeInterval { Double(bytes.count) / 48000 }
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    var bytes = Data()
    var playing = false
    var inputFinished = false
    var stopped = false
    var drainOnFinish = false
    let finished: @MainActor (Bool) -> Void
    init(finished: @escaping @MainActor (Bool) -> Void) { self.finished = finished }
    func play() -> Bool {
        playing = true
        return true
    }
    func pause() { playing = false }
    func stop() {
        stopped = true
        playing = false
    }
    func appendPCM(_ data: Data) throws { bytes.append(data) }
    func finishInput() throws {
        inputFinished = true
        if drainOnFinish { drain() }
    }
    func drain() {
        playing = false
        finished(true)
    }
}

final class StreamingPlaybackTests: XCTestCase {
    func testPCMDecoderKeepsSamplesSplitAcrossChunksAndRejectsAnIncompleteSample() throws {
        var decoder = StreamingPCMDecoder()
        XCTAssertEqual(decoder.decode(Data([0])), [])
        XCTAssertEqual(decoder.decode(Data([128, 0, 0, 255])), [-1, 0])
        XCTAssertEqual(decoder.decode(Data([127])), [Float(32767) / 32768])
        XCTAssertNoThrow(try decoder.finish())
        _ = decoder.decode(Data([1]))
        XCTAssertThrowsError(try decoder.finish())
    }
    @MainActor func testControllerPausesResumesAndWaitsForPlaybackDrainAfterInputEnds() throws {
        let audio = AudioController()
        var fixture: StreamPlayerFixture!
        var finished = 0
        audio.makeStream = { callback in
            fixture = StreamPlayerFixture(finished: callback)
            return fixture
        }
        try audio.startStreaming(completed: { finished += 1 })
        try audio.appendStreaming(Data(repeating: 1, count: 4800))
        XCTAssertTrue(fixture.playing)
        XCTAssertEqual(audio.duration, 0.1, accuracy: 0.001)
        audio.togglePause()
        XCTAssertTrue(audio.paused)
        audio.togglePause()
        XCTAssertFalse(audio.paused)
        try audio.finishStreaming()
        XCTAssertTrue(fixture.inputFinished)
        XCTAssertEqual(finished, 0, "The server finishing is not the speakers finishing")
        fixture.drain()
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(audio.isStreaming)
        audio.stop()
    }
    @MainActor func testLiveReplyPlaysBeforeGenerationEndsSavesTheFullReplyAndNeverReplaysIt() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        var fixture: StreamPlayerFixture!
        app.audio.makeStream = { callback in
            fixture = StreamPlayerFixture(finished: callback)
            return fixture
        }
        let chunk = Data(repeating: 0, count: 4800)
        let audioArrived = expectation(description: "First audio arrived")
        let gate = TestGate()
        var deferred = 0
        app.speech.conversationReply = { _, request, callbacks in
            XCTAssertEqual(request.conversationID, app.selectedID)
            callbacks.audio?(chunk)
            audioArrived.fulfill()
            await gate.wait()
            app.deferredToolAction = { deferred += 1 }
            var result = RealtimeAccumulator()
            result.audio = chunk
            result.text = "Reply"
            result.done = true
            try callbacks.response(result)
        }
        app.requestReply(history: [], text: "", pcm: chunk, audioFile: "saved.wav", conversationID: app.selectedID!)
        let request = try XCTUnwrap(app.currentTask)
        await fulfillment(of: [audioArrived], timeout: 2)
        XCTAssertTrue(fixture.playing)
        XCTAssertTrue(app.speaking)
        XCTAssertEqual(app.turn.activity, .generating)
        XCTAssertEqual(app.quickTalkPlan, .pause)
        XCTAssertEqual(app.conversation?.messages.count, 1, "Playback starts before the complete reply is saved")
        await gate.release()
        await request.value
        XCTAssertEqual(app.turn.activity, .playing)
        XCTAssertEqual(deferred, 0)
        let message = try XCTUnwrap(app.conversation?.messages.last)
        XCTAssertEqual(message.text, "Reply")
        let file = try XCTUnwrap(message.audio)
        XCTAssertEqual(try AudioFile.pcm(app.store.root.appendingPathComponent(file)), chunk)
        // Completion must keep its coordinator alive after the network job has already returned.
        fixture.drain()
        XCTAssertEqual(app.turn.activity, .idle)
        XCTAssertFalse(app.speaking)
        XCTAssertEqual(deferred, 1)
        fixture.drain()
        XCTAssertEqual(deferred, 1)
        app.stop()
    }
    @MainActor func testStopIgnoresLateAudioAndLatePlaybackCompletion() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        var fixture: StreamPlayerFixture!
        var players = 0
        app.audio.makeStream = { callback in
            players += 1
            fixture = StreamPlayerFixture(finished: callback)
            return fixture
        }
        let started = expectation(description: "Stream started")
        let gate = TestGate()
        app.speech.conversationReply = { _, _, callbacks in
            callbacks.audio?(Data(repeating: 0, count: 4800))
            started.fulfill()
            await gate.wait()
            callbacks.audio?(Data(repeating: 1, count: 4800))
            var result = RealtimeAccumulator()
            result.text = "Late reply"
            try callbacks.response(result)
        }
        app.requestReply(
            history: [], text: "", pcm: Data(repeating: 0, count: 4800), audioFile: "saved.wav",
            conversationID: app.selectedID!)
        let request = try XCTUnwrap(app.currentTask)
        await fulfillment(of: [started], timeout: 2)
        app.stop()
        await gate.release()
        await request.value
        fixture.drain()
        XCTAssertTrue(fixture.stopped)
        XCTAssertEqual(fixture.bytes.count, 4800)
        XCTAssertEqual(players, 1)
        XCTAssertEqual(app.conversation?.messages.count, 1)
        XCTAssertEqual(app.turn.activity, .idle)
        XCTAssertFalse(app.speaking)
    }
    @MainActor func testProviderFailureStopsAudioAlreadyBeingPlayed() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        var fixture: StreamPlayerFixture!
        app.audio.makeStream = { callback in
            fixture = StreamPlayerFixture(finished: callback)
            return fixture
        }
        app.speech.conversationReply = { _, _, callbacks in
            callbacks.audio?(Data(repeating: 0, count: 4800))
            throw URLError(.networkConnectionLost)
        }
        app.requestReply(
            history: [], text: "", pcm: Data(repeating: 0, count: 4800), audioFile: "saved.wav",
            conversationID: app.selectedID!)
        await app.currentTask?.value
        XCTAssertTrue(fixture.stopped)
        XCTAssertFalse(app.audio.isStreaming)
        XCTAssertFalse(app.speaking)
        XCTAssertNotNil(app.error)
        XCTAssertEqual(app.turn.activity, .idle)
    }
    @MainActor func testContinuousPreferencePersistsAndModeConversationAndStopResetTheConnection() {
        let defaults = makePreferences()
        let app = makeApp(demo: true, preferences: defaults)
        XCTAssertFalse(app.continuousConversation)
        var resets = 0
        app.speech.resetConversation = { resets += 1 }
        app.continuousConversation = true
        XCTAssertEqual(resets, 1)
        XCTAssertTrue(app.settings.conversationService().reuseConnection)
        XCTAssertFalse(app.settings.practiceService().reuseConnection)
        XCTAssertTrue(
            PreferencesStore(defaults, importLegacy: false, allowExternalControl: false).continuousConversation)
        app.selectedID = UUID()
        XCTAssertEqual(resets, 2)
        app.stop()
        XCTAssertEqual(resets, 3)
        app.continuousConversation = false
        XCTAssertEqual(resets, 4)
        XCTAssertFalse(
            PreferencesStore(defaults, importLegacy: false, allowExternalControl: false).continuousConversation)
    }
}
