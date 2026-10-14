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
    @MainActor func testFaintSpeakerLeakDoesNotCutOffAReplyButTheUserCanStillInterrupt() async throws {
        let (app, device) = appAndDevice()
        var requests = 0
        app.speech.conversationReply = { [weak self] _, _, callbacks in
            requests += 1
            try self?.respond(callbacks)
        }
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        device.continuation.yield(speech + silence)
        await waitUntil { app.turn.activity == .playing }
        let player = try XCTUnwrap(device.players.first)
        var faint = Data()
        for index in stride(from: 0, to: speech.count, by: 2) {
            let sample = Int16(bitPattern: UInt16(speech[index]) | UInt16(speech[index + 1]) << 8)
            var value = Int16(Int(sample) / 100).littleEndian
            withUnsafeBytes(of: &value) { faint.append(contentsOf: $0) }
        }
        // Consume synchronously so the checks cannot pass before the input task processes the leak.
        app.handsFree?.consume(faint + silence)
        XCTAssertFalse(player.stopped)
        XCTAssertFalse(app.conversation?.messages.last?.interrupted == true)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(app.turn.activity, .playing)
        app.handsFree?.consume(speech)
        XCTAssertTrue(player.stopped, "A normal spoken interruption must still stop the reply")
        app.handsFree?.consume(silence)
        await waitUntil { requests == 2 && app.turn.activity == .playing }
        app.stop()
    }
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
        app.speech.transcribe = { _, _ in throw AppFailure("Test transcription unavailable.") }
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
    @MainActor func testInterruptedGenerationRecoversOnlyItsTranscriptWhileTheNextTurnPlays() async throws {
        let (app, device) = appAndDevice()
        let generation = TestGate()
        let recognition = TestGate()
        var requests = 0
        var recoveries = 0
        app.speech.conversationReply = { [weak self] _, _, callbacks in
            requests += 1
            if requests == 1 {
                await generation.wait()
                throw CancellationError()
            }
            try self?.respond(callbacks)
        }
        app.speech.transcribe = { url, _ in
            recoveries += 1
            XCTAssertEqual(url.lastPathComponent, app.conversation?.messages.first?.audio)
            await recognition.wait()
            return "Recovered interrupted speech"
        }
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        device.continuation.yield(speech + silence)
        await waitUntil { requests == 1 }
        let original = try XCTUnwrap(app.currentTask)
        let voiceID = try XCTUnwrap(app.conversation?.messages.first?.id)
        device.continuation.yield(speech + silence)
        await waitUntil { requests == 2 && app.turn.activity == .playing }
        await generation.release()
        await original.value
        await waitUntil { recoveries == 1 }
        XCTAssertTrue(app.transcribingMessageIDs.contains(voiceID))
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState, .pending)
        await recognition.release()
        await waitUntil { !app.transcribingMessageIDs.contains(voiceID) }
        XCTAssertEqual(app.conversation?.messages.first?.text, "Recovered interrupted speech")
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState, .completed)
        XCTAssertEqual(app.conversation?.messages.count, 3, "Recovery must not add a message or another reply")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(app.turn.activity, .playing)
        XCTAssertTrue(app.handsFreeActive)
        app.stop()
    }
    @MainActor func testStopOrConversationChangeBeforeCancelledReplyExitsCannotStartRecovery() async throws {
        for changeConversation in [false, true] {
            let (app, device) = appAndDevice()
            let gate = TestGate()
            var requests = 0
            app.speech.conversationReply = { _, _, _ in
                requests += 1
                await gate.wait()
                throw CancellationError()
            }
            app.speech.transcribe = { _, _ in
                XCTFail("A stopped session must not start a transcription request")
                return "Unexpected"
            }
            app.toggleConversationVoice()
            await waitUntil { app.handsFreeActive }
            device.continuation.yield(speech + silence)
            await waitUntil { requests == 1 }
            let original = try XCTUnwrap(app.currentTask)
            app.handsFree?.consume(speech)
            if changeConversation { app.newChat() } else { app.stop() }
            await gate.release()
            await original.value
            XCTAssertTrue(app.transcripts.isIdle)
            XCTAssertFalse(app.handsFreeActive)
        }
    }
    @MainActor func testStopOrManualEditRejectsLateAutomaticRecovery() async throws {
        for edit in [false, true] {
            let (app, device) = appAndDevice()
            let generation = TestGate()
            let recognition = TestGate()
            var requests = 0
            var recoveries = 0
            app.speech.conversationReply = { _, _, _ in
                requests += 1
                await generation.wait()
                throw CancellationError()
            }
            app.speech.transcribe = { _, _ in
                recoveries += 1
                await recognition.wait()
                return "Stale recognition"
            }
            app.toggleConversationVoice()
            await waitUntil { app.handsFreeActive }
            device.continuation.yield(speech + silence)
            await waitUntil { requests == 1 }
            let original = try XCTUnwrap(app.currentTask)
            let voiceID = try XCTUnwrap(app.conversation?.messages.first?.id)
            app.handsFree?.consume(speech)
            await generation.release()
            await original.value
            await waitUntil { recoveries == 1 }
            let job = try XCTUnwrap(app.transcripts.task(for: voiceID))
            if edit { app.editTranscript(voiceID, text: "My correction") } else { app.stop() }
            await recognition.release()
            await job.value
            XCTAssertEqual(app.conversation?.messages.first?.text, edit ? "My correction" : "")
            XCTAssertEqual(app.conversation?.messages.first?.transcriptionState, edit ? .completed : .interrupted)
            XCTAssertTrue(app.transcripts.isIdle)
            app.stop()
        }
    }
    @MainActor func testFaintNoiseAfterPlaybackTailDoesNotCreateAnEmptyVoiceMessage() async throws {
        let (app, device) = appAndDevice()
        var now = Date()
        var requests = 0
        app.recordingNow = { now }
        app.speech.conversationReply = { [weak self] _, _, callbacks in
            requests += 1
            try self?.respond(callbacks)
        }
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        device.continuation.yield(speech + silence)
        await waitUntil { app.turn.activity == .playing }
        device.players.last?.drain()
        now = now.addingTimeInterval(5)
        var faint = Data()
        for index in stride(from: 0, to: speech.count, by: 2) {
            let sample = Int16(bitPattern: UInt16(speech[index]) | UInt16(speech[index + 1]) << 8)
            var value = Int16(Int(sample) / 100).littleEndian
            withUnsafeBytes(of: &value) { faint.append(contentsOf: $0) }
        }
        app.handsFree?.consume(faint + silence)
        XCTAssertEqual(app.conversation?.messages.count, 2)
        XCTAssertFalse(app.handsFreeSpeechDetected)
        XCTAssertEqual(requests, 1)
        app.handsFree?.consume(speech + silence)
        await waitUntil { requests == 2 && app.turn.activity == .playing }
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
