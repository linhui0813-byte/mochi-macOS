import MochiAutomation
import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

final class AuditFixG5Tests: XCTestCase {
    private func folder() throws -> URL {
        let url = TestScratch.folder("mochi-g5")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func voiceLibrary(_ audio: String, state: TranscriptionState? = nil) -> Library {
        var message = Message(role: "user", text: "", audio: audio)
        message.transcriptionState = state
        var chat = Conversation()
        chat.messages = [message]
        var library = Library()
        library.conversations = [chat]
        return library
    }

    // MARK: Earlier-copy recovery

    func testEarlierCopyNeverRestoresPendingTranscriptions() throws {
        let root = try folder()
        let store = LibraryStore(root: root)
        try store.save(voiceLibrary("recording-\(UUID()).wav", state: .pending))
        try store.save(Library())
        XCTAssertEqual(try store.loadPrevious().conversations[0].messages[0].transcriptionState, .interrupted)
        try Data("damaged".utf8).write(to: store.file)
        let restored = try LibraryStore(root: root).restorePrevious()
        XCTAssertEqual(restored.conversations[0].messages[0].transcriptionState, .interrupted)
    }
    func testRestoreThatCannotSetTheFileAsideChangesNothing() throws {
        let root = try folder()
        let store = LibraryStore(root: root)
        try store.save(Library())
        try store.save(Library())
        try Data("damaged".utf8).write(to: store.file)
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        defer { chmod(root.path, 0o700) }
        XCTAssertThrowsError(try LibraryStore(root: root).restorePrevious())
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertEqual(try String(contentsOf: store.file), "damaged")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                $0.hasPrefix("library-unreadable-")
            })
    }
    func testCleanupKeepsRecordingsTheEarlierCopyNeeds() throws {
        let root = try folder()
        let store = LibraryStore(root: root)
        let kept = "recording-\(UUID()).wav"
        try Data([1]).write(to: root.appendingPathComponent(kept))
        try store.save(voiceLibrary(kept))
        try store.save(Library())
        try store.cleanupOrphanedAudio(Library())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(kept).path))
    }
    func testCleanupRemovesExportStagingLeftByAForceQuit() throws {
        let root = try folder()
        let staging = root.appendingPathComponent("\(LibraryStore.exportStagingPrefix)\(UUID())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data([1]).write(to: staging.appendingPathComponent("recording-\(UUID()).wav"))
        try LibraryStore(root: root).cleanupOrphanedAudio(Library())
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    // MARK: Backups

    func testBackupPackageIsCreatedExclusively() throws {
        let root = try folder()
        let package = root.appendingPathComponent("nested/backup.mochilibrary")
        try LibraryBackup.write(Library(), from: root, to: package)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("library.json").path))
        XCTAssertThrowsError(try LibraryBackup.write(Library(), from: root, to: package))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("library.json").path))
    }
    func testAudioOfItemsAddedMeanwhileIsDiscardedAfterAnImport() throws {
        let source = try folder()
        let target = try folder()
        try Data([1]).write(to: source.appendingPathComponent("voice.wav"))
        let imported = voiceLibrary("voice.wav")
        let package = source.appendingPathComponent("backup.mochilibrary")
        try LibraryBackup.write(imported, from: source, to: package)
        let read = try LibraryBackup.read(package)
        let prepared = try LibraryBackup.prepareMerge(read, from: package, into: Library(), root: target)
        XCTAssertEqual(prepared.copied.count, 1)
        var local = Library()
        local.conversations = [Conversation()]
        local.conversations[0].id = read.conversations[0].id
        XCTAssertEqual(try LibraryBackup.apply(prepared, to: &local), 0)
        LibraryBackup.discard(prepared, keeping: local)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.copied[0].path))

        var fresh = Library()
        XCTAssertEqual(try LibraryBackup.merge(read, from: package, into: &fresh, root: target), 1)
        let audio = try XCTUnwrap(fresh.conversations[0].messages[0].audio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(audio).path))
    }

    // MARK: Search

    func testMessageSearchesAgreeOnLegacyVoicePlaceholders() {
        var chat = Conversation()
        let placeholder = Message(role: "user", text: "Voice message (transcript unavailable)", audio: "a.wav")
        let typed = Message(role: "user", text: "A voice message about tea")
        chat.messages = [placeholder, typed]
        XCTAssertEqual(chat.matchingMessage("voice message")?.id, typed.id)
        XCTAssertEqual(chat.matchingMessageIDs("voice message"), [typed.id])
        XCTAssertNil(chat.matchingMessage("  "))
        XCTAssertEqual(chat.matchingMessageIDs(""), [])
    }

    // MARK: Settings

    private final class SharedSettings: ConversationSettingsHolder {
        var instructions = "Before"
        var characterName: String? = "Ava"
        var preferences = ConversationPreferences()
    }
    func testFailedPatchLeavesEvenAClassConformerUntouched() {
        var settings = SharedSettings()
        let patch = ConversationSettingsPatch(
            instructions: "After", characterName: .set("Bea"), speed: .set(9), coaching: .direct)
        XCTAssertThrowsError(try patch.apply(to: &settings))
        XCTAssertEqual(settings.instructions, "Before")
        XCTAssertEqual(settings.characterName, "Ava")
        XCTAssertEqual(settings.preferences, ConversationPreferences())
        XCTAssertNoThrow(try ConversationSettingsPatch(characterName: .clear, speed: .set(1.2)).apply(to: &settings))
        XCTAssertNil(settings.characterName)
        XCTAssertEqual(settings.preferences.speed, 1.2)
    }
    func testSpeedRuleIsSharedByDecodingAndValidation() throws {
        for speed in [0.25, 1.5, 1.0] { XCTAssertTrue(ConversationPreferences.isValidSpeed(speed)) }
        for speed in [0.2, 1.6, .nan, .infinity] { XCTAssertFalse(ConversationPreferences.isValidSpeed(speed)) }
        let decoded = try JSONDecoder().decode(
            ConversationPreferences.self, from: Data(#"{"speed": 2, "coaching": 5}"#.utf8))
        XCTAssertNil(decoded.speed)
        XCTAssertEqual(decoded.coaching, .natural)
    }

    // MARK: Templates

    func testBuiltinIDsAreReservedFromOneDefinition() {
        XCTAssertEqual(ConversationTemplate.reservedIDs, Set(ConversationTemplate.builtins.map(\.id)))
        XCTAssertEqual(ConversationTemplate.reservedIDs.count, ConversationTemplate.builtins.count)
        XCTAssertTrue(ConversationTemplate.builtins.allSatisfy(\.isBuiltin))
    }
    func testInstructionPreviewUsesTheValidationLimit() {
        var t = ConversationTemplate(title: "Long", instructions: "x")
        t.instructions = String(repeating: "y", count: MochiTools.maxInstructions + 5)
        let preview = t.representation()
        XCTAssertEqual((preview["instructions"] as? String)?.count, MochiTools.maxInstructions)
        XCTAssertEqual((preview["fields_truncated"] as? [String: Bool])?["instructions"], true)
    }

    // MARK: Data folder

    func testLegacyFolderWithoutALibraryNeverBlocksStartup() throws {
        let support = try folder()
        let legacy = support.appendingPathComponent(AppIdentity.legacyDataDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data([1]).write(to: legacy.appendingPathComponent(".DS_Store"))
        let mochi = support.appendingPathComponent(AppIdentity.name)
        try FileManager.default.createDirectory(at: mochi, withIntermediateDirectories: true)
        try Data([1]).write(to: mochi.appendingPathComponent("builtin-preview.wav"))
        XCTAssertFalse(AppIdentity.needsMigration(in: support))
        XCTAssertEqual(try AppIdentity.prepareDataDirectory(in: support).path, mochi.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mochi.appendingPathComponent(".DS_Store").path))
    }

    // MARK: Errors

    func testOutOfSpaceIsFoundBeneathManyWrappers() {
        var error: Error = POSIXError(.ENOSPC)
        for i in 0..<10 { error = AppFailure("Wrapper \(i)", underlying: error) }
        XCTAssertTrue(ErrorChain.isOutOfSpace(error))
        XCTAssertEqual(ErrorChain.causes(of: error).count, 6)
    }
}
