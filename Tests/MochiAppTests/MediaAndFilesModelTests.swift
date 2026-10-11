import AVFoundation
import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp

final class MediaAndFilesModelTests: XCTestCase {
    private func toneWAV(in folder: URL, name: String = "attempt.wav") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var pcm = Data()
        for i in 0..<12000 {
            var value = Int16(sin(2 * Double.pi * 180 * Double(i) / 24000) * 12000).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        let url = folder.appendingPathComponent(name)
        try PCM.wav(pcm).write(to: url)
        return url
    }

    // MARK: Microphone interruption (M7)

    @MainActor func testMicrophoneThatStopsMidTakeEndsTheRecordingWithAnExplanation() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        var recorded: URL?
        var active = true
        app.media.permission = { true }
        app.media.record = { url in
            recorded = url
            try Data([1, 2, 3]).write(to: url)
        }
        app.media.stopRecording = {
            defer { recorded = nil }
            return recorded
        }
        app.media.recordingActive = { active }
        app.recordingSleep = { _ in await Task.yield() }
        app.toggleRecord()
        await waitUntil { app.turn.activity == .recording }
        let file = try XCTUnwrap(recorded)
        active = false
        await waitUntil { app.turn.activity == .idle }
        XCTAssertTrue(app.error?.contains("microphone disconnected") == true, app.error ?? "no error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
    }

    // MARK: Practice attempts (M15)

    @MainActor func testPracticeAttemptIsSavedWithItsPitch() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        app.startHelp()
        app.editEnglish("Let me think.")
        app.beginPractice()
        let take = try toneWAV(in: root)
        app.media.permission = { true }
        app.media.record = { _ in }
        app.media.stopRecording = { take }
        app.toggleRecord()
        await waitUntil { app.turn.activity == .recording }
        app.finishRecording()
        await waitUntil { !app.busy }
        XCTAssertEqual(app.expression?.attempts.map(\.file), ["attempt.wav"])
        XCTAssertTrue(app.attemptPitch.contains { $0.hz != nil })
        XCTAssertEqual(try LibraryStore(root: root).load().expressions.first?.attempts.count, 1)
    }

    // MARK: Files chosen by the user (M15, M8)

    @MainActor func testImportedReferenceIsCopiedAndAnalysed() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.startHelp()
        app.editEnglish("Hello.")
        app.beginPractice()
        app.importReference(from: fixtureURL("reference.mp3"))
        await waitUntil { !app.busy }
        let name = try XCTUnwrap(app.expression?.reference)
        XCTAssertTrue(name.hasPrefix("import-"))
        XCTAssertEqual(app.expression?.referenceKind, "Imported reference")
        XCTAssertFalse(app.referencePitch.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.store.root.appendingPathComponent(name).path))
    }
    @MainActor func testBackupRoundTripRunsInTheBackgroundAndKeepsEditsMadeMeanwhile() async throws {
        let source = makeApp(root: makeTemporaryFolder())
        let recording = try toneWAV(in: source.store.root, name: "recording-\(UUID().uuidString).wav")
        source.append(
            Message(role: "user", text: "From the backup", audio: recording.lastPathComponent), to: source.selectedID!)
        let package = makeTemporaryFolder().appendingPathComponent("Backup.mochilibrary")
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        let export = try XCTUnwrap(source.exportLibraryBackup(to: package))
        XCTAssertNotNil(source.libraryTransfer)
        await export.value
        XCTAssertNil(source.libraryTransfer)
        XCTAssertNil(source.error)

        let target = makeApp(root: makeTemporaryFolder())
        let local = try XCTUnwrap(target.selectedID)
        let task = try XCTUnwrap(target.importLibraryBackup(from: package))
        target.renameChat(local, title: "Edited during import")
        await task.value
        XCTAssertNil(target.error)
        XCTAssertEqual(target.library.conversations.first(where: { $0.id == local })?.title, "Edited during import")
        let imported = try XCTUnwrap(
            target.library.conversations.first { $0.messages.first?.text == "From the backup" })
        let audio = try XCTUnwrap(imported.messages.first?.audio)
        XCTAssertTrue(audio.hasPrefix("import-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.store.root.appendingPathComponent(audio).path))
    }
    @MainActor func testImportThatCannotBeSavedLeavesNoCopiedAudio() async throws {
        let source = makeApp(root: makeTemporaryFolder())
        let recording = try toneWAV(in: source.store.root, name: "recording-\(UUID().uuidString).wav")
        source.append(Message(role: "user", text: "Voice", audio: recording.lastPathComponent), to: source.selectedID!)
        let package = makeTemporaryFolder().appendingPathComponent("Backup.mochilibrary")
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        await source.exportLibraryBackup(to: package)?.value
        let root = makeTemporaryFolder()
        let target = makeApp(root: root)
        try Data("changed outside Mochi".utf8).write(to: root.appendingPathComponent("library.json"))
        await target.importLibraryBackup(from: package)?.value
        XCTAssertNotNil(target.error)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("import-") })
    }
    @MainActor func testTranscriptIsWrittenToTheChosenFile() throws {
        let app = makeApp(root: makeTemporaryFolder())
        let id = try XCTUnwrap(app.selectedID)
        app.append(Message(role: "user", text: "Exported words"), to: id)
        let url = makeTemporaryFolder().appendingPathComponent("t.md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        app.exportChats([id], json: false, to: url)
        XCTAssertTrue(try String(contentsOf: url).contains("Exported words"))
        XCTAssertEqual(app.historyFeedback, "Transcript exported.")
    }

    // MARK: Launch migration (M8)

    @MainActor func testOlderLibraryIsMovedInTheBackgroundAtLaunch() async throws {
        let support = makeTemporaryFolder()
        var library = Library()
        library.conversations = [Conversation(title: "Before the rename")]
        try LibraryStore(root: support.appendingPathComponent(AppIdentity.legacyDataDirectory)).save(library)
        let app = makeApp(applicationSupport: support)
        XCTAssertNotNil(app.startupProgress)
        XCTAssertFalse(app.libraryReadable)
        await waitUntil { app.libraryReadable }
        XCTAssertNil(app.startupProgress)
        XCTAssertNil(app.error)
        XCTAssertEqual(app.conversation?.title, "Before the rename")
        XCTAssertEqual(app.store.root.lastPathComponent, AppIdentity.name)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: support.appendingPathComponent(AppIdentity.name).appendingPathComponent("library.json").path))
    }
    @MainActor func testBlockedMigrationRevealsTheFolderThatNeedsAttention() async throws {
        let support = makeTemporaryFolder()
        try LibraryStore(root: support.appendingPathComponent(AppIdentity.legacyDataDirectory)).save(Library())
        let mochi = support.appendingPathComponent(AppIdentity.name)
        try FileManager.default.createDirectory(at: mochi, withIntermediateDirectories: true)
        try Data([1]).write(to: mochi.appendingPathComponent("stray.wav"))
        let app = makeApp(applicationSupport: support)
        await waitUntil { app.startupProgress == nil }
        XCTAssertFalse(app.libraryReadable)
        XCTAssertTrue(app.error?.contains("already contains other files") == true, app.error ?? "no error")
        XCTAssertEqual(app.dataFolder.path, mochi.path)
        XCTAssertEqual(app.store.root.path, mochi.path)
    }
}
