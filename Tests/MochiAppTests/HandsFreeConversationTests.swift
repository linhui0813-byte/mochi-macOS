import AVFoundation
import MochiCore
import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiApp
@testable import MochiProviders

@MainActor private final class HandsFreeTestPlayer: StreamingPlaybackPlayer {
    var duration: TimeInterval = 1
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    var stopped = false
    var audio = Data()
    let finished: @MainActor (Bool) -> Void
    init(_ finished: @escaping @MainActor (Bool) -> Void) { self.finished = finished }
    func play() -> Bool { !stopped }
    func pause() {}
    func stop() { stopped = true }
    func appendPCM(_ data: Data) throws { audio.append(data) }
    func finishInput() throws {}
    func drain() { finished(true) }
}
@MainActor private final class HandsFreeTestDevice: HandsFreeAudioDevice {
    var starts = 0, stops = 0
    var players: [HandsFreeTestPlayer] = []
    var continuation: AsyncThrowingStream<Data, Error>.Continuation!
    var startError: Error?
    func start() throws -> AsyncThrowingStream<Data, Error> {
        starts += 1
        if let startError { throw startError }
        return AsyncThrowingStream { continuation = $0 }
    }
    func makePlayer(finished: @escaping @MainActor (Bool) -> Void) throws -> any StreamingPlaybackPlayer {
        let player = HandsFreeTestPlayer(finished)
        players.append(player)
        return player
    }
    func stop() {
        stops += 1
        continuation?.finish()
    }
}

final class HandsFreeConversationTests: XCTestCase {
    @MainActor func testAudioStartupErrorKeepsTheStageAndCodeWithoutExposingSystemDescriptions() {
        let underlying = NSError(
            domain: NSOSStatusErrorDomain, code: -10875,
            userInfo: [NSLocalizedDescriptionKey: "private audio device details"])
        for echo in [true, false] {
            let failure = HandsFreeAudio.startupFailure(underlying, enablingEchoCancellation: echo)
            XCTAssertTrue(failure.message.contains("-10875"))
            XCTAssertTrue(failure.message.contains(echo ? "echo cancellation" : "continuous conversation audio"))
            XCTAssertFalse(failure.message.contains("private audio device details"))
            XCTAssertEqual((failure.underlying as NSError?)?.code, -10875)
        }
    }
    private var speech: Data { SpeechFixture.voiced(frames: 45) }
    private var silence: Data { Data(repeating: 0, count: 960 * 75) }
    @MainActor func testSpeechStatusDistinguishesDetectedSpeechFromWaitingAndSending() async throws {
        let (app, device) = appAndDevice()
        let gate = TestGate()
        app.speech.conversationReply = { _, _, _ in await gate.wait() }
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        XCTAssertFalse(app.handsFreeSpeechDetected)
        XCTAssertEqual(app.status, String(localized: "Listening · speak naturally"))
        device.continuation.yield(speech)
        await waitUntil { app.handsFreeSpeechDetected }
        XCTAssertEqual(app.status, String(localized: "Hearing you · pause to send"))
        device.continuation.yield(silence)
        await waitUntil { app.turn.activity == .generating }
        XCTAssertFalse(app.handsFreeSpeechDetected)
        XCTAssertEqual(app.status, String(localized: "Thinking · microphone stays on"))
        app.stop()
        XCTAssertFalse(app.handsFreeSpeechDetected)
        await gate.release()
    }
    @MainActor private func appAndDevice() -> (AppModel, HandsFreeTestDevice) {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        app.continuousConversation = true
        app.media.permission = { true }
        let device = HandsFreeTestDevice()
        app.makeHandsFreeAudio = { device }
        return (app, device)
    }
    @MainActor private func respond(_ callbacks: ReplyCallbacks) throws {
        var result = RealtimeAccumulator()
        result.inputTranscript = "A spoken turn"
        result.transcriptionState = .completed
        callbacks.transcription(result)
        result.audio = Data(repeating: 1, count: 4800)
        result.text = "Heard beginning and an unheard ending."
        result.done = true
        callbacks.audio?(result.audio)
        try callbacks.response(result)
    }
    @MainActor func testOnePressStartsTwoAutomaticTurnsAndReleaseDoesNotSend() async throws {
        let (app, device) = appAndDevice()
        var requests = 0
        app.speech.conversationReply = { [weak self] _, _, callbacks in
            requests += 1
            try self?.respond(callbacks)
        }
        var now = Date()
        app.recordingNow = { now }
        app.shortcutTriggered(.talk, pressed: true)
        await waitUntil { app.handsFreeActive }
        now = now.addingTimeInterval(2)
        app.shortcutTriggered(.talk, pressed: false)
        XCTAssertTrue(app.handsFreeActive)
        XCTAssertEqual(device.starts, 1)
        XCTAssertEqual(requests, 0)
        device.continuation.yield(silence)
        await Task.yield()
        XCTAssertEqual(requests, 0, "An open silent microphone must not send a message")
        for turn in 1...2 {
            device.continuation.yield(speech + silence)
            await waitUntil { requests == turn && app.turn.activity == .playing }
            device.players.last?.drain()
            XCTAssertEqual(app.turn.activity, .recording, "Listen again without any shortcut event")
            XCTAssertTrue(app.handsFreeActive)
        }
        XCTAssertEqual(app.conversation?.messages.count, 4)
        app.shortcutTriggered(.talk, pressed: true)
        XCTAssertFalse(app.handsFreeActive)
        XCTAssertEqual(app.turn.activity, .idle)
        XCTAssertEqual(device.stops, 1)
    }
    @MainActor func testSpeechInterruptsQueuedPlaybackAndNextContextExcludesTheUnheardEnding() async throws {
        let (app, device) = appAndDevice()
        var inputs: [ConversationRequest] = []
        app.speech.conversationReply = { [weak self] _, input, callbacks in
            inputs.append(input)
            try self?.respond(callbacks)
        }
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        device.continuation.yield(speech + silence)
        await waitUntil { inputs.count == 1 && app.turn.activity == .playing }
        let first = try XCTUnwrap(device.players.first)
        device.continuation.yield(speech)
        await waitUntil { first.stopped }
        XCTAssertTrue(app.conversation?.messages.last?.interrupted == true)
        XCTAssertTrue(app.handsFreeActive, "Interruption stops only the reply, not the microphone")
        device.continuation.yield(silence)
        await waitUntil { inputs.count == 2 && app.turn.activity == .playing }
        XCTAssertFalse(inputs[1].history.last?.contextText?.contains("unheard ending") == true)
        first.drain()
        XCTAssertEqual(app.turn.activity, .playing, "A stale speaker completion cannot reopen or stop a later turn")
        app.stop()
    }
    @MainActor func testInterruptionDuringGenerationRejectsLateAudioAndReplyCallbacks() async throws {
        let (app, device) = appAndDevice()
        let gate = TestGate()
        var requests = 0
        var oldOperation: Task<Void, Never>?
        app.speech.conversationReply = { [weak self, weak app] _, _, callbacks in
            requests += 1
            if requests == 1 {
                callbacks.audio?(Data(repeating: 0, count: 4800))
                oldOperation = app?.currentTask
                await gate.wait()
            }
            try self?.respond(callbacks)
        }
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        device.continuation.yield(speech + silence)
        await waitUntil { device.players.count == 1 }
        let first = device.players[0]
        device.continuation.yield(speech + silence)
        await waitUntil { requests == 2 && app.turn.activity == .playing }
        await gate.release()
        await oldOperation?.value
        XCTAssertTrue(first.stopped)
        XCTAssertEqual(first.audio.count, 4800, "Cancelled generation must not schedule its late audio")
        XCTAssertEqual(app.conversation?.messages.filter { $0.role == "assistant" }.count, 1)
        app.stop()
    }
    @MainActor func testStopConversationChangeAndModeOffCloseCaptureAndIgnoreLateInput() async throws {
        for operation in 0..<3 {
            let (app, device) = appAndDevice()
            var requests = 0
            app.speech.conversationReply = { _, _, _ in requests += 1 }
            app.toggleConversationVoice()
            await waitUntil { app.handsFreeActive }
            let session = try XCTUnwrap(app.handsFree)
            if operation == 0 {
                app.stop()
            } else if operation == 1 {
                app.selectedID = UUID()
            } else {
                app.continuousConversation = false
            }
            session.consume(speech + silence)
            XCTAssertFalse(app.handsFreeActive)
            XCTAssertEqual(device.stops, 1)
            XCTAssertEqual(requests, 0)
            XCTAssertEqual(app.turn.activity, .idle)
        }
    }
    @MainActor func testDeniedPermissionOrUnavailableEchoCancellationDoesNotLeaveTheMicrophoneRunning() async throws {
        for denied in [true, false] {
            let (app, device) = appAndDevice()
            app.media.permission = { !denied }
            device.startError = AppFailure("Echo cancellation is unavailable.")
            app.toggleConversationVoice()
            await waitUntil { app.error != nil }
            XCTAssertFalse(app.handsFreeActive)
            XCTAssertEqual(app.turn.activity, .idle)
            XCTAssertEqual(device.starts, denied ? 0 : 1)
        }
    }
    @MainActor func testCaptureFailureEndsTheSessionInsteadOfSilentlyContinuing() async throws {
        let (app, device) = appAndDevice()
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        device.continuation.finish(throwing: AppFailure("Audio device disconnected."))
        await waitUntil { !app.handsFreeActive }
        XCTAssertTrue(app.error?.contains("disconnected") == true)
        XCTAssertEqual(device.stops, 1)
    }
    @MainActor func testProviderFailureClosesTheOpenMicrophone() async throws {
        let (app, device) = appAndDevice()
        app.speech.conversationReply = { _, _, _ in throw URLError(.networkConnectionLost) }
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        device.continuation.yield(speech + silence)
        await waitUntil { app.error != nil }
        XCTAssertFalse(app.handsFreeActive)
        XCTAssertEqual(device.stops, 1)
        XCTAssertEqual(app.turn.activity, .idle)
    }
    @MainActor func testStopBeforePermissionReturnsCannotOpenTheMicrophoneLater() async throws {
        for operation in 0..<4 {
            let (app, device) = appAndDevice()
            let gate = TestGate()
            app.media.permission = {
                await gate.wait()
                return true
            }
            app.toggleConversationVoice()
            let permission = try XCTUnwrap(app.currentTask)
            if operation == 0 {
                app.stop()
            } else if operation == 1 {
                app.selectedID = UUID()
            } else if operation == 2 {
                app.continuousConversation = false
            } else {
                app.shortcutTriggered(.talk, pressed: true)
            }
            await gate.release()
            await permission.value
            XCTAssertEqual(device.starts, 0)
            XCTAssertFalse(app.handsFreeActive)
            XCTAssertFalse(app.handsFreeStarting)
            XCTAssertEqual(app.turn.activity, .idle)
        }
    }
    func testCaptureConverterProducesMono24kPCMFromStereo48kWithoutHardware() async throws {
        let input = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4800))
        buffer.frameLength = 4800
        for index in 0..<4800 {
            let value = Float(sin(Double(index) * 2 * .pi * 180 / 48000) * 0.25)
            buffer.floatChannelData?[0][index] = value
            buffer.floatChannelData?[1][index] = value
        }
        var sink: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error> { sink = $0 }
        let converter = try HandsFreePCMConverter(format: input, continuation: sink)
        converter.receive(buffer)
        var iterator = stream.makeAsyncIterator()
        let next = try await iterator.next()
        let pcm = try XCTUnwrap(next)
        XCTAssertGreaterThan(pcm.count, 4000)
        XCTAssertLessThanOrEqual(pcm.count, 4800)
        XCTAssertEqual(pcm.count % 2, 0)
        sink.finish()
    }
}
