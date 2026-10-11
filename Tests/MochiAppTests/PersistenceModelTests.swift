import Darwin
import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp

final class PersistenceModelTests: XCTestCase {
    // MARK: Opening the library (H2, H3, L2)

    @MainActor func testFirstLaunchWritesItsLibraryImmediately() {
        let root = makeTemporaryFolder()
        _ = makeApp(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
    }
    @MainActor func testNewerLibraryNamesTheRealReasonAndIsNotOverwritten() throws {
        let root = makeTemporaryFolder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data(#"{"version":4,"conversations":[],"expressions":[]}"#.utf8)
        try bytes.write(to: root.appendingPathComponent("library.json"))
        let app = makeApp(root: root)
        XCTAssertTrue(app.error?.contains("newer version of Mochi") == true, app.error ?? "no error")
        XCTAssertFalse(app.canRestorePreviousLibrary)
        app.draft = "Typed"
        app.save()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), bytes)
    }
    @MainActor func testDamagedLibraryOffersTheEarlierCopyAndRestoresIt() throws {
        let root = makeTemporaryFolder()
        let first = makeApp(root: root)
        first.renameChat(first.selectedID!, title: "Before damage")
        first.draft = "later"
        first.save()
        try Data("damaged".utf8).write(to: root.appendingPathComponent("library.json"))
        let app = makeApp(root: root)
        XCTAssertTrue(app.canRestorePreviousLibrary)
        XCTAssertTrue(app.error?.contains("Restore Earlier Copy") == true, app.error ?? "no error")
        app.restorePreviousLibrary()
        XCTAssertNil(app.error)
        XCTAssertFalse(app.canRestorePreviousLibrary)
        XCTAssertTrue(app.libraryReadable)
        XCTAssertEqual(app.conversation?.title, "Before damage")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                $0.hasPrefix("library-unreadable-")
            })
        XCTAssertEqual(makeApp(root: root).conversation?.title, "Before damage")
    }

    // MARK: Typing (H1)

    @MainActor func testTypingIsWrittenAfterAPauseWithoutChangingTheAutomationRevision() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        app.externalControlEnabled = true
        defer { app.externalControlEnabled = false }
        app.saveDelay = 20_000_000
        let id = try XCTUnwrap(app.selectedID)
        let revision = app.controlRevision
        for character in "Hello there" { app.draft.append(character) }
        XCTAssertEqual(app.controlRevision, revision)
        XCTAssertTrue(app.hasPendingSave)
        XCTAssertEqual(try LibraryStore(root: root).load().conversations[0].draft, "")
        await waitUntil { !app.hasPendingSave }
        XCTAssertEqual(try LibraryStore(root: root).load().conversations[0].draft, "Hello there")
        // An automation client holding the old revision is not rejected because the user typed.
        let result = try app.executeTool(
            "save_expression",
            arguments: ["conversation_id": id.uuidString, "expected_revision": revision, "english": "Let me think."],
            origin: .external)
        XCTAssertEqual(result["ok"] as? Bool, true)
    }
    @MainActor func testSwitchingConversationsWritesPendingTypingAtOnce() throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        let first = try XCTUnwrap(app.selectedID)
        app.draft = "Keep me"
        app.newChat()
        XCTAssertFalse(app.hasPendingSave)
        XCTAssertEqual(
            try LibraryStore(root: root).load().conversations.first(where: { $0.id == first })?.draft, "Keep me")
    }

    // MARK: Failure messages (M3, M4)

    @MainActor func testSaveFailureMessagesNameTheRealCause() {
        let app = makeApp(demo: true)
        func message(_ error: Error) -> String {
            app.persistenceMessage(error, action: "Test", fallback: "fallback", diskFull: "disk full")
        }
        XCTAssertEqual(message(POSIXError(.ENOSPC)), "disk full")
        XCTAssertEqual(
            message(AppFailure("The library file on disk was written by a newer version of Mochi.")),
            "The library file on disk was written by a newer version of Mochi.")
        XCTAssertEqual(message(POSIXError(.EACCES)), "fallback")
    }
    @MainActor func testReplyKeepsItsTextWhenItsAudioCannotBeWritten() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        // Only the audio write fails; the library itself still saves, so the reply text reaches disk.
        app.writeReplyAudio = { _, _ in throw POSIXError(.EACCES) }
        app.speech.conversationReply = { _, _, callbacks in
            var reply = RealtimeAccumulator()
            reply.text = "Hello back."
            reply.audio = Data(repeating: 0, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        app.draft = "Hello"
        app.send()
        await waitUntil { !app.busy }
        let reply = try XCTUnwrap(app.conversation?.messages.last)
        XCTAssertEqual(reply.role, "assistant")
        XCTAssertEqual(reply.text, "Hello back.")
        XCTAssertNil(reply.audio)
        XCTAssertTrue(app.error?.contains("without its audio") == true, app.error ?? "no error")
        let saved = try LibraryStore(root: app.store.root).load().conversations.first { $0.id == app.selectedID }
        XCTAssertEqual(saved?.messages.map(\.text), ["Hello", "Hello back."])
    }

    // MARK: Creating examples (moved from the retired ElevenLabs tests)

    @MainActor private func practisingApp() -> AppModel {
        let app = makeApp(root: makeTemporaryFolder())
        app.startHelp()
        app.editEnglish("Let me think.")
        return app
    }
    @MainActor func testExampleUsesThePracticeVoiceAndForwardsRegeneration() async throws {
        let app = practisingApp()
        let fixture = fixtureURL("reference.mp3")
        app.settings.builtInPracticeVoice = "cedar"
        var calls: [(String, String, Bool)] = []
        app.speech.referenceAudio = { text, service, root, force in
            calls.append((text, service.voice, force))
            let url = root.appendingPathComponent("builtin-test.mp3")
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.copyItem(at: fixture, to: url)
            }
            return url
        }
        app.render()
        await waitUntil { !app.busy }
        XCTAssertNil(app.error)
        XCTAssertEqual(app.expression?.reference, "builtin-test.mp3")
        XCTAssertEqual(app.expression?.referenceKind, "Cedar · Codex voice")
        XCTAssertFalse(app.referencePitch.isEmpty)
        app.render(force: true)
        await waitUntil { !app.busy }
        XCTAssertEqual(calls.map(\.0), ["Let me think.", "Let me think."])
        XCTAssertEqual(calls.map(\.1), ["cedar", "cedar"])
        XCTAssertEqual(calls.map(\.2), [false, true])
    }
    @MainActor func testFailedExampleKeepsTheSavedOne() async throws {
        let app = practisingApp()
        app.ensureExpression()
        app.expression?.reference = "saved.wav"
        app.expression?.referenceKind = "Original"
        app.speech.referenceAudio = { _, _, _, _ in throw AppFailure("The example did not match the sentence exactly.")
        }
        app.render(force: true)
        await waitUntil { !app.busy }
        XCTAssertEqual(app.error, "The example did not match the sentence exactly.")
        XCTAssertEqual(app.expression?.reference, "saved.wav")
        XCTAssertEqual(app.expression?.referenceKind, "Original")
    }
    @MainActor func testStoppingWhileAnExampleIsCreatedCannotReplaceTheSavedOne() async throws {
        let app = practisingApp()
        let gate = TestGate()
        let started = expectation(description: "Example requested")
        app.ensureExpression()
        app.expression?.reference = "saved.wav"
        app.expression?.referenceKind = "Original"
        app.speech.referenceAudio = { _, _, root, _ in
            started.fulfill()
            await gate.wait()
            return root.appendingPathComponent("late.wav")
        }
        app.render(force: true)
        await fulfillment(of: [started], timeout: 2)
        let job = try XCTUnwrap(app.currentTask)
        app.stop()
        await gate.release()
        await job.value
        XCTAssertFalse(app.busy)
        XCTAssertNil(app.error)
        XCTAssertEqual(app.expression?.reference, "saved.wav")
        XCTAssertEqual(app.expression?.referenceKind, "Original")
    }
}
