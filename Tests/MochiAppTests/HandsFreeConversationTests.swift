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
@MainActor private final class EndPhraseTestDevice: EndPhraseDevice {
    var matched: (() -> Void)?
    var failed: ((Error) -> Void)?
    var armed = false
    var stops = 0
    var appended: [Data] = []
    func start(matched: @escaping @MainActor () -> Void, failed: @escaping @MainActor (Error) -> Void) {
        self.matched = matched
        self.failed = failed
    }
    func beginTurn() { armed = true }
    func endTurn() { armed = false }
    func append(_ pcm: Data) throws { appended.append(pcm) }
    func stop() {
        stops += 1
        armed = false
    }
}

final class HandsFreeConversationTests: XCTestCase {
    @MainActor func testPhraseStatusUsesTheLiveSessionAndReportsRecognitionFailureWithoutStoppingCapture()
        async throws
    {
        let (app, audio) = appAndDevice()
        let phrase = EndPhraseTestDevice()
        app.makeEndPhraseDevice = { _ in phrase }
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        app.cancelEndingPhrasePreparation()
        XCTAssertEqual(app.endingPhraseStatus, String(localized: "Not prepared"))
        XCTAssertEqual(app.endingPhraseDisplayStatus, String(localized: "Ready"))
        phrase.failed?(AppFailure("Recognition test failure"))
        XCTAssertEqual(app.endingPhraseDisplayStatus, String(localized: "Unavailable · pause detection still works"))
        XCTAssertTrue(app.handsFreeActive)
        XCTAssertEqual(audio.stops, 0)
        XCTAssertEqual(phrase.stops, 1)
        app.stop()
        XCTAssertEqual(app.endingPhraseDisplayStatus, String(localized: "Not prepared"))
    }
    @MainActor func testEndingPhraseIgnoresContinuedSpeechDuringGenerationAndPlaybackThenResumes() async throws {
        let (app, audio) = appAndDevice()
        app.settings.endingPhrase = "finished now"
        let phrase = EndPhraseTestDevice()
        let generation = TestGate()
        var requests = 0
        var now = Date()
        app.recordingNow = { now }
        app.makeEndPhraseDevice = { _ in phrase }
        app.speech.conversationReply = { [weak self] _, input, callbacks in
            requests += 1
            if requests == 1 {
                XCTAssertEqual(input.endingPhrase, "finished now")
                XCTAssertTrue(input.resolvedInstructions.contains("speech before its first occurrence"))
                await generation.wait()
            }
            try self?.respond(callbacks)
        }
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        let session = try XCTUnwrap(app.handsFree)
        session.consume(speech)
        phrase.matched?()
        await waitUntil { requests == 1 }
        let reply = try XCTUnwrap(app.currentTask)
        let replyEpoch = app.turn.epoch
        now = now.addingTimeInterval(20)
        for _ in 0..<3 { session.consume(speech + silence) }
        phrase.matched?()
        XCTAssertTrue(session.inputPausedForReply)
        XCTAssertFalse(reply.isCancelled)
        XCTAssertEqual(app.turn.epoch, replyEpoch)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(app.conversation?.messages.count, 1)
        XCTAssertEqual(app.status, String(localized: "Thinking · listening paused"))
        XCTAssertEqual(app.recordingLevel, -80)
        XCTAssertFalse(app.handsFreeSpeechDetected)
        XCTAssertFalse(phrase.armed)
        XCTAssertEqual(phrase.appended.last, Data(repeating: 0, count: speech.count + silence.count))
        await generation.release()
        await reply.value
        await waitUntil { app.turn.activity == .playing }
        let player = try XCTUnwrap(audio.players.first)
        session.consume(speech + silence)
        XCTAssertFalse(player.stopped)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(app.status, String(localized: "Mochi is speaking · listening paused"))
        XCTAssertFalse(app.conversation?.messages.last?.interrupted == true)
        app.audio.togglePause()
        session.consume(speech + silence)
        XCTAssertTrue(session.inputPausedForReply)
        XCTAssertEqual(app.status, String(localized: "Playback paused · listening paused"))
        XCTAssertFalse(player.stopped)
        app.audio.togglePause()
        player.drain()
        XCTAssertFalse(session.inputPausedForReply)
        XCTAssertEqual(app.status, String(localized: "Listening · speak naturally"))
        XCTAssertTrue(app.handsFreeActive)
        // The next ordinary pause-ended turn still permits the user's usual spoken interruption.
        session.consume(speech + silence)
        await waitUntil { requests == 2 && app.turn.activity == .playing }
        let next = try XCTUnwrap(audio.players.last)
        session.consume(speech)
        XCTAssertTrue(next.stopped)
        app.stop()
    }
    @MainActor func testExplicitStopOrConversationChangeEndsAnEndingPhraseProtectedReply() async throws {
        for operation in 0..<3 {
            let (app, audio) = appAndDevice()
            let phrase = EndPhraseTestDevice()
            let generation = TestGate()
            var requests = 0
            app.makeEndPhraseDevice = { _ in phrase }
            app.speech.conversationReply = { [weak self] _, _, callbacks in
                requests += 1
                await generation.wait()
                try self?.respond(callbacks)
            }
            app.toggleConversationVoice()
            await waitUntil { app.handsFreeActive }
            let session = try XCTUnwrap(app.handsFree)
            session.consume(speech)
            phrase.matched?()
            await waitUntil { requests == 1 }
            let reply = try XCTUnwrap(app.currentTask)
            XCTAssertTrue(session.inputPausedForReply)
            if operation == 0 {
                app.shortcutTriggered(.talk, pressed: true)
            } else if operation == 1 {
                app.newChat()
            } else {
                app.continuousConversation = false
            }
            await generation.release()
            await reply.value
            session.consume(speech + silence)
            phrase.matched?()
            XCTAssertFalse(app.handsFreeActive)
            XCTAssertEqual(audio.stops, 1)
            XCTAssertEqual(phrase.stops, 1)
            XCTAssertTrue(audio.players.isEmpty)
            XCTAssertEqual(app.turn.activity, .idle)
            XCTAssertEqual(requests, 1)
        }
    }
    @MainActor func testSpokenEndingPhraseSendsWithoutQuietKeepsListeningAndRejectsDuplicateResults() async throws {
        let (app, audio) = appAndDevice()
        let phrase = EndPhraseTestDevice()
        var now = Date()
        var requests = 0
        app.recordingNow = { now }
        app.makeEndPhraseDevice = { value in
            XCTAssertEqual(value.text, "over over")
            return phrase
        }
        app.speech.conversationReply = { [weak self] _, input, callbacks in
            requests += 1
            XCTAssertEqual(input.endingPhrase, "over over")
            XCTAssertTrue(input.resolvedInstructions.contains("end-of-turn recording control"))
            try self?.respond(callbacks)
        }
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        audio.continuation.yield(speech)
        await waitUntil { app.handsFreeSpeechDetected }
        XCTAssertTrue(phrase.armed)
        phrase.matched?()
        phrase.matched?()
        await waitUntil { requests == 1 && app.turn.activity == .playing }
        XCTAssertEqual(app.conversation?.messages.count, 2)
        XCTAssertTrue(app.handsFreeActive)
        audio.players.last?.drain()
        now = now.addingTimeInterval(1)
        phrase.matched?()
        XCTAssertEqual(requests, 1, "A late match while waiting must not submit an empty recording")
        audio.continuation.yield(speech)
        await waitUntil { app.handsFreeSpeechDetected }
        phrase.matched?()
        await waitUntil { requests == 2 && app.turn.activity == .playing }
        app.stop()
        let count = app.conversation?.messages.count
        phrase.matched?()
        XCTAssertEqual(app.conversation?.messages.count, count)
        XCTAssertEqual(phrase.stops, 1)
    }
    @MainActor func testCustomPhrasePreparationDoesNotStartTheMicrophoneAndIsUsedByTheSession() async throws {
        let (app, audio) = appAndDevice()
        app.settings.endingPhrase = "finished now"
        let phrase = EndPhraseTestDevice()
        var preparations = 0
        app.makeEndPhraseDevice = { value in
            preparations += 1
            XCTAssertEqual(value.text, "finished now")
            return phrase
        }
        app.checkEndingPhrase()
        await waitUntil { !app.endingPhrasePreparing }
        XCTAssertEqual(audio.starts, 0)
        XCTAssertFalse(app.handsFreeActive)
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        XCTAssertEqual(preparations, 1, "Use the already prepared detector once")
        app.stop()
    }
    @MainActor func testStopModeChangeAndConversationChangeDuringPhrasePreparationNeverStartCapture() async throws {
        for operation in 0..<3 {
            let (app, audio) = appAndDevice()
            let gate = TestGate()
            let prepared = expectation(description: "Phrase preparation started")
            let phrase = EndPhraseTestDevice()
            app.makeEndPhraseDevice = { _ in
                prepared.fulfill()
                await gate.wait()
                return phrase
            }
            app.toggleConversationVoice()
            let task = try XCTUnwrap(app.currentTask)
            await fulfillment(of: [prepared], timeout: 2)
            if operation == 0 {
                app.stop()
            } else if operation == 1 {
                app.continuousConversation = false
            } else {
                app.newChat()
            }
            await gate.release()
            await task.value
            XCTAssertEqual(audio.starts, 0)
            XCTAssertEqual(phrase.stops, 1)
            XCTAssertFalse(app.handsFreeActive)
            XCTAssertFalse(app.endingPhrasePreparing)
        }
    }
    @MainActor func testUnavailablePhraseRecognitionPreservesPauseDetection() async throws {
        let (app, audio) = appAndDevice()
        app.makeEndPhraseDevice = { _ in throw AppFailure("Local speech model unavailable.") }
        app.speech.conversationReply = { [weak self] _, input, callbacks in
            XCTAssertNil(input.endingPhrase)
            try self?.respond(callbacks)
        }
        app.toggleConversationVoice()
        await waitUntil { app.handsFreeActive }
        XCTAssertNotNil(app.notice)
        audio.continuation.yield(speech + silence)
        await waitUntil { app.turn.activity == .playing }
        XCTAssertEqual(app.conversation?.messages.count, 2)
        app.stop()
    }
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
