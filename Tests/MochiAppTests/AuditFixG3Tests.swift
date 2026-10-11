import MochiCore
import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiApp

final class AuditFixG3Tests: XCTestCase {
    private func tone(seconds: Double = 0.5) -> Data {
        var pcm = Data()
        for i in 0..<Int(24000 * seconds) {
            var value = Int16(sin(2 * Double.pi * 180 * Double(i) / 24000) * 12000).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        return PCM.wav(pcm)
    }

    /// A fake microphone whose take is written by `content`; the clock never ticks on its own.
    @MainActor private func recordingApp(root: URL, content: Data, active: @escaping () -> Bool) -> (
        AppModel, () -> URL?
    ) {
        let app = makeApp(root: root)
        var recorded: URL?
        var last: URL?
        app.media.permission = { true }
        app.media.record = { url in
            recorded = url
            last = url
            try content.write(to: url)
        }
        app.media.stopRecording = {
            defer { recorded = nil }
            return recorded
        }
        app.media.recordingActive = active
        app.recordingSleep = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        return (app, { last })
    }

    // MARK: Recording completion and interruption (#2, #18, #19, #20)

    @MainActor func testTakeThatReachedTheTimeLimitIsKeptNotTreatedAsInterrupted() async throws {
        let root = makeTemporaryFolder()
        var active = true
        let (app, file) = recordingApp(root: root, content: tone(), active: { active })
        // The recorder confirms a successful stop at its limit; elapsed time alone no longer decides.
        app.media.recordingFinished = { !active }
        var now = Date()
        app.recordingNow = { now }
        app.startHelp()
        app.recordMeaning()
        await waitUntil { app.turn.activity == .recording }
        now = now.addingTimeInterval(59.8)
        active = false
        app.finishRecording()
        await waitUntil { app.thoughtRecording != nil && !app.busy }
        XCTAssertNil(app.error)
        let name = try XCTUnwrap(file()?.lastPathComponent)
        XCTAssertEqual(app.thoughtRecording, name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        app.stop()
    }

    @MainActor func testFailedTakeAtTheTimeLimitIsDiscardedNotKept() async throws {
        let root = makeTemporaryFolder()
        var active = true
        let (app, file) = recordingApp(root: root, content: tone(), active: { active })
        app.media.recordingInterrupted = { !active }
        var now = Date()
        app.recordingNow = { now }
        app.startHelp()
        app.recordMeaning()
        await waitUntil { app.turn.activity == .recording }
        now = now.addingTimeInterval(59.8)
        active = false
        app.finishRecording()
        XCTAssertTrue(app.error?.contains("microphone disconnected") == true, app.error ?? "no error")
        XCTAssertNil(app.thoughtRecording)
        let url = try XCTUnwrap(file())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testFinishingAfterTheMicrophoneStoppedDiscardsThePartialTake() async throws {
        let root = makeTemporaryFolder()
        var active = true
        let (app, file) = recordingApp(root: root, content: tone(), active: { active })
        app.startHelp()
        app.recordMeaning()
        await waitUntil { app.turn.activity == .recording }
        active = false
        app.finishRecording()
        // With no confirmed outcome the decision waits briefly for the recorder's report, then discards.
        await waitUntil { app.error != nil }
        XCTAssertTrue(app.error?.contains("microphone disconnected") == true, app.error ?? "no error")
        XCTAssertNil(app.thoughtRecording)
        let url = try XCTUnwrap(file())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testUnreadableThoughtRecordingIsRemovedAndReported() async throws {
        let root = makeTemporaryFolder()
        let (app, file) = recordingApp(root: root, content: Data([1, 2, 3]), active: { true })
        app.startHelp()
        app.recordMeaning()
        await waitUntil { app.turn.activity == .recording }
        app.finishRecording()
        await waitUntil { !app.busy }
        XCTAssertNotNil(app.error)
        XCTAssertNil(app.thoughtRecording)
        XCTAssertNotEqual(app.notice, "Your thought is recorded locally. Listen, then choose Transcribe.")
        let url = try XCTUnwrap(file())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testUnreadableVoiceMessageIsRemovedAndNothingIsSent() async throws {
        let root = makeTemporaryFolder()
        let (app, file) = recordingApp(root: root, content: Data([1, 2, 3]), active: { true })
        app.toggleRecord()
        await waitUntil { app.turn.activity == .recording }
        app.finishRecording()
        await waitUntil { !app.busy }
        XCTAssertNotNil(app.error)
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
        let url = try XCTUnwrap(file())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Replies and the greeting (#10, #11, #12)

    @MainActor func testAudioOnlyReplyThatCannotBeWrittenIsReportedAsLost() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        // Only the audio write fails; a failed message save now stops the send, which AuditFixR2BTests covers.
        app.writeReplyAudio = { _, _ in throw POSIXError(.EACCES) }
        app.speech.conversationReply = { _, _, callbacks in
            var reply = RealtimeAccumulator()
            reply.audio = Data(repeating: 0, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        app.draft = "Hello"
        app.send()
        await waitUntil { !app.busy }
        XCTAssertFalse(app.conversation?.messages.contains { $0.role == "assistant" } == true)
        XCTAssertTrue(app.error?.contains("reply could not be saved") == true, app.error ?? "no error")
    }

    @MainActor func testGreetingUsesTheConversationSpeechSpeed() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        let id = try XCTUnwrap(app.selectedID)
        let index = try XCTUnwrap(app.library.conversations.firstIndex { $0.id == id })
        app.library.conversations[index].preferences.speed = 0.8
        app.media.permission = { true }
        var speed: Double?
        app.speech.referenceAudio = { _, service, _, _ in
            speed = service.options.speed
            throw AppFailure("Stop after capturing the service.")
        }
        app.toggleConversationVoice()
        await waitUntil { speed != nil && !app.busy }
        XCTAssertEqual(speed, 0.8)
    }

    // MARK: Help Me Say This (#14, #15, #16, #49)

    @MainActor func testEditedThoughtIsSavedWithTheExistingExpression() throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.startHelp()
        app.meaning = "Old meaning"
        app.editEnglish("Hello there.")
        app.beginPractice()
        app.editThought()
        app.meaning = "New meaning"
        XCTAssertTrue(app.saveExpression())
        XCTAssertEqual(app.library.expressions.first?.meaning, "New meaning")
    }

    @MainActor func testReopeningAnExpressionWithoutItsConversationReusesTheReplacement() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        let item = PracticeExpression(conversationID: UUID(), meaning: "Meaning", english: "Orphaned sentence")
        app.library.expressions = [item]
        app.openExpression(item)
        await waitUntil { !app.busy }
        let replacement = try XCTUnwrap(app.selectedID)
        XCTAssertEqual(app.library.expressions.first?.conversationID, replacement)
        let count = app.library.conversations.count
        app.resume()
        app.openExpression(try XCTUnwrap(app.library.expressions.first))
        await waitUntil { !app.busy }
        XCTAssertEqual(app.library.conversations.count, count)
        XCTAssertEqual(app.selectedID, replacement)
    }

    @MainActor func testMissingReferenceDoesNotHideTheLatestAttemptContour() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        try tone().write(to: root.appendingPathComponent("attempt.wav"))
        var item = PracticeExpression(conversationID: try XCTUnwrap(app.selectedID), meaning: "", english: "Hello.")
        item.reference = "missing.wav"
        item.attempts = [Attempt(file: "attempt.wav")]
        app.library.expressions = [item]
        app.openExpression(item)
        await waitUntil { !app.busy }
        XCTAssertTrue(app.referencePitch.isEmpty)
        XCTAssertFalse(app.attemptPitch.isEmpty)
        XCTAssertNotNil(app.error)
    }

    @MainActor func testReferenceCannotBeImportedWithoutEnglish() throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        app.startHelp()
        app.editEnglish("Hello.")
        app.beginPractice()
        app.editEnglish("   ")
        XCTAssertFalse(app.canImportReference)
        app.importReference(from: fixtureURL("reference.mp3"))
        XCTAssertFalse(app.busy)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("import-") })
    }

    // MARK: History (#1, #17, #23)

    @MainActor func testPermanentDeletionKeepsTheRecordingHeldForUndo() throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        let selected = try XCTUnwrap(app.selectedID)
        let other = Conversation(title: "Other")
        app.library.conversations.append(other)
        let url = root.appendingPathComponent("shared.wav")
        try Data([1]).write(to: url)
        let message = Message(role: "user", text: "Mine", audio: "shared.wav")
        app.append(message, to: selected)
        app.append(Message(role: "user", text: "Theirs", audio: "shared.wav"), to: other.id)
        app.deleteMessage(message.id)
        app.deleteChats([other.id])
        app.permanentDeleteIDs = [other.id]
        app.permanentlyDeleteChats()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        app.undoMessageDeletion()
        XCTAssertEqual(app.conversation?.messages.first?.audio, "shared.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testArchivingTheSelectedChatSavesTheReplacementSelection() throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        let first = try XCTUnwrap(app.selectedID)
        app.append(Message(role: "user", text: "First"), to: first)
        app.newChat()
        let second = try XCTUnwrap(app.selectedID)
        app.append(Message(role: "user", text: "Second"), to: second)
        app.select(first)
        app.archiveChats([first])
        XCTAssertEqual(app.selectedID, second)
        XCTAssertEqual(makeApp(root: root).selectedID, second)
    }

    @MainActor func testRestoringTheEarlierCopyShowsTheScopeOfTheSelectedChat() throws {
        let root = makeTemporaryFolder()
        let first = makeApp(root: root)
        let id = try XCTUnwrap(first.selectedID)
        first.append(Message(role: "user", text: "Archived words"), to: id)
        first.archiveChats([id])
        first.showHistory(.archived)
        XCTAssertEqual(first.selectedID, id)
        first.save()
        try Data("damaged".utf8).write(to: root.appendingPathComponent("library.json"))
        let app = makeApp(root: root)
        XCTAssertTrue(app.canRestorePreviousLibrary)
        app.restorePreviousLibrary()
        XCTAssertEqual(app.selectedID, id)
        XCTAssertEqual(app.historyScope, .archived)
    }

    // MARK: Job bookkeeping (#66, #110)

    func testBeginningAReplacementTranscriptJobCancelsTheOldTask() {
        var jobs = TranscriptJobs()
        let id = UUID()
        _ = jobs.begin(id)
        let old = Task<Void, Never> { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        jobs.attach(old, to: id)
        _ = jobs.begin(id)
        XCTAssertTrue(old.isCancelled)
        XCTAssertNil(jobs.task(for: id))
        jobs.cancelAll()
    }

    @MainActor func testFinishedExclusiveJobReleasesItsTask() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.speech.textReply = { _, _ in "ready" }
        app.checkConnection()
        XCTAssertNotNil(app.currentTask)
        await waitUntil { !app.busy && app.currentTask == nil }
        XCTAssertEqual(app.serviceStatus, "Verified · text response received")
    }
}
