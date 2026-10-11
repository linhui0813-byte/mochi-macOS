import Darwin
import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp

final class AuditFixR2BTests: XCTestCase {
    // MARK: #10 A message that cannot be saved is not sent

    @MainActor func testUnsavedMessageKeepsTheDraftAndIsNotSent() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        defer { chmod(root.path, 0o700) }
        let id = try XCTUnwrap(app.selectedID)
        let title = app.conversation?.title
        var requests = 0
        app.speech.conversationReply = { _, _, callbacks in
            requests += 1
            var reply = RealtimeAccumulator()
            reply.text = "Hello back."
            reply.done = true
            try callbacks.response(reply)
        }
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        app.draft = "  Hello  "
        app.send()
        XCTAssertEqual(app.draft, "  Hello  ")
        XCTAssertNotNil(app.error)
        XCTAssertFalse(app.busy)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(app.conversation?.messages.count, 0)
        XCTAssertEqual(app.conversation?.title, title)
        XCTAssertEqual(app.conversation?.draft, "  Hello  ")

        XCTAssertEqual(chmod(root.path, 0o700), 0)
        app.send()
        await waitUntil { !app.busy }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(app.draft, "")
        XCTAssertNil(app.error)
        let saved = try LibraryStore(root: root).load().conversations.first { $0.id == id }
        XCTAssertEqual(saved?.messages.map(\.text), ["Hello", "Hello back."])
        XCTAssertEqual(saved?.draft, "")
    }

    // MARK: #11 A reply that cannot be saved is never reported as saved

    @MainActor func testUnsavedTextReplyIsNotReportedAsSavedWithoutAudio() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        defer { chmod(root.path, 0o700) }
        app.writeReplyAudio = { _, _ in throw POSIXError(.EACCES) }
        app.speech.conversationReply = { _, _, callbacks in
            // The message saved; the library becomes unwritable before the reply arrives.
            XCTAssertEqual(chmod(root.path, 0o500), 0)
            var reply = RealtimeAccumulator()
            reply.text = "Hello back."
            reply.audio = Data(repeating: 0, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        app.draft = "Hello"
        app.send()
        await waitUntil { !app.busy }
        let error = try XCTUnwrap(app.error)
        XCTAssertFalse(error.contains("was saved"), error)
        XCTAssertTrue(error.contains("Could not save your conversation"), error)
    }

    // MARK: #53 Cancelling an import leaves the library unchanged

    @MainActor func testCancellingTheImportTaskChangesNothing() async throws {
        let source = makeApp(root: makeTemporaryFolder())
        source.append(Message(role: "user", text: "From the backup"), to: try XCTUnwrap(source.selectedID))
        let package = makeTemporaryFolder().appendingPathComponent("Backup.mochilibrary")
        await source.exportLibraryBackup(to: package)?.value
        XCTAssertNil(source.error)

        let target = makeApp(root: makeTemporaryFolder())
        let before = target.library
        let task = try XCTUnwrap(target.importLibraryBackup(from: package))
        task.cancel()
        await task.value
        await waitUntil { target.libraryTransfer == nil }
        XCTAssertNil(target.error)
        XCTAssertNil(target.historyFeedback)
        XCTAssertEqual(target.library.conversations.map(\.id), before.conversations.map(\.id))
        XCTAssertFalse(
            target.library.conversations.contains { $0.messages.contains { $0.text == "From the backup" } })
        let onDisk = try LibraryStore(root: target.store.root).load()
        XCTAssertEqual(onDisk.conversations.map(\.id), before.conversations.map(\.id))
    }

    // MARK: #69 One Stop writes the library once

    @MainActor func testStopSavesOnceSoTheEarlierCopyIsTheStateBeforeStop() throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        app.startHelp()
        XCTAssertTrue(app.practice)
        XCTAssertTrue(app.save())
        // Typing in an existing draft is only scheduled, so disk still lacks it when Stop runs.
        app.meaning = "Typed just before Stop"
        XCTAssertTrue(app.hasPendingSave)
        XCTAssertTrue(app.stop())
        let store = LibraryStore(root: root)
        XCTAssertEqual(try store.load().conversations.first?.helpDraft?.meaning, "Typed just before Stop")
        // A second save would have replaced the earlier copy with the state Stop wrote.
        let previous = try String(contentsOf: store.previousFile, encoding: .utf8)
        XCTAssertFalse(previous.contains("Typed just before Stop"))
    }

    // MARK: #74 Stop Preview belongs to the preview alone

    @MainActor func testStopPreviewControlsOnlyThePreviewsOwnTurn() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        let fixture = fixtureURL("reference.mp3")
        app.speech.referenceAudio = { _, _, root, _ in
            let url = root.appendingPathComponent("preview-test.mp3")
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.copyItem(at: fixture, to: url)
            }
            return url
        }
        try FileManager.default.copyItem(at: fixture, to: app.store.root.appendingPathComponent("message.mp3"))
        XCTAssertFalse(app.previewActive)

        app.previewBuiltIn("cedar")
        XCTAssertTrue(app.previewActive, "Generating the preview belongs to the preview")
        await waitUntil { app.playbackFile == "preview-test.mp3" }
        XCTAssertTrue(app.previewActive)
        app.stopPreview()
        XCTAssertFalse(app.previewActive)
        XCTAssertEqual(app.turn.activity, .idle)
        XCTAssertNil(app.playbackFile)

        app.previewBuiltIn("cedar")
        await waitUntil { app.playbackFile == "preview-test.mp3" }
        // Message playback replaces the preview, so Stop Preview no longer reaches it.
        app.play("message.mp3")
        XCTAssertEqual(app.playbackFile, "message.mp3")
        XCTAssertFalse(app.previewActive)
        app.stopPreview()
        XCTAssertEqual(app.turn.activity, .playing)
        XCTAssertEqual(app.playbackFile, "message.mp3")
    }
}
