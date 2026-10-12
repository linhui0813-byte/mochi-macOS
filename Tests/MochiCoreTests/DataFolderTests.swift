import Darwin
import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

final class DataFolderTests: XCTestCase {
    func testPreviousMochiPreferencesSurviveIdentityChangeWithoutOverwritingNewValues() {
        let name = "mochi-identity-test-\(UUID())"
        let defaults = TestScratch.preferences(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("cedar", forKey: "conversationVoice")
        AppIdentity.migratePreferences(
            into: defaults,
            legacy: [
                "conversationVoice": "marin", "builtInPracticeVoice": "sage", "practiceVoiceOptions": Data([1, 2]),
                "voiceGreetingHistory": ["Hello", "Hi"], "unknown": "ignore",
            ])
        AppIdentity.migratePreferences(into: defaults, legacy: ["builtInPracticeVoice": "ash"])
        XCTAssertEqual(defaults.string(forKey: "conversationVoice"), "cedar")
        XCTAssertEqual(defaults.string(forKey: "builtInPracticeVoice"), "sage")
        XCTAssertEqual(defaults.data(forKey: "practiceVoiceOptions"), Data([1, 2]))
        XCTAssertEqual(defaults.stringArray(forKey: "voiceGreetingHistory"), ["Hello", "Hi"])
        XCTAssertNil(defaults.object(forKey: "unknown"))
    }

    func testLibraryCopyPreservesOriginalAndDoesNotOverwriteMochi() throws {
        let parent = temporary()
        defer { try? FileManager.default.removeItem(at: parent) }
        let legacy = parent.appendingPathComponent(AppIdentity.legacyDataDirectory)
        let store = LibraryStore(root: legacy)
        var library = Library()
        library.conversations = [Conversation(title: "Existing chat")]
        try store.save(library)
        let original = try Data(contentsOf: store.file)
        try Data([1, 2]).write(to: legacy.appendingPathComponent("recording.wav"))
        let migrated = try AppIdentity.prepareDataDirectory(in: parent)
        XCTAssertEqual(migrated.lastPathComponent, "Mochi")
        XCTAssertEqual(try Data(contentsOf: migrated.appendingPathComponent("library.json")), original)
        XCTAssertEqual(try Data(contentsOf: migrated.appendingPathComponent("recording.wav")), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: store.file), original)
        var changed = try LibraryStore(root: migrated).load()
        changed.conversations[0].title = "New local title"
        try LibraryStore(root: migrated).save(changed)
        _ = try AppIdentity.prepareDataDirectory(in: parent)
        XCTAssertEqual(try LibraryStore(root: migrated).load().conversations[0].title, "New local title")
    }
    func testPreferencesOnlyCopyKnownMissingValues() {
        let name = "mochi-test-\(UUID())"
        let defaults = TestScratch.preferences(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("new-model", forKey: "model")
        AppIdentity.migratePreferences(
            into: defaults,
            legacy: ["model": "old-model", "clone": "test-clone", "auth": "api", "unknown": "do not copy"])
        XCTAssertEqual(defaults.string(forKey: "model"), "new-model")
        // Preferences from retired features are left behind.
        for key in ["clone", "auth", "unknown"] { XCTAssertNil(defaults.object(forKey: key), key) }
    }
    func testNewInstallAndUnsafeLegacyRoot() throws {
        let parent = temporary()
        let other = temporary()
        defer { for p in [parent, other] { try? FileManager.default.removeItem(at: p) } }
        let fresh = try AppIdentity.prepareDataDirectory(in: parent)
        XCTAssertEqual(fresh.lastPathComponent, "Mochi")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: parent.appendingPathComponent(AppIdentity.legacyDataDirectory), withDestinationURL: other)
        XCTAssertThrowsError(try AppIdentity.prepareDataDirectory(in: parent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }
    func testCorruptAndFutureLegacyDataAreNotMigratedOrChanged() throws {
        for future in [false, true] {
            let parent = temporary()
            defer { try? FileManager.default.removeItem(at: parent) }
            let legacy = parent.appendingPathComponent(AppIdentity.legacyDataDirectory)
            let store = LibraryStore(root: legacy)
            try store.prepare()
            if future {
                var library = Library()
                library.version = Library.currentVersion + 1
                try JSONEncoder().encode(library).write(to: store.file)
            } else {
                try Data("broken".utf8).write(to: store.file)
            }
            let before = try Data(contentsOf: store.file)
            XCTAssertThrowsError(try AppIdentity.prepareDataDirectory(in: parent))
            XCTAssertEqual(try Data(contentsOf: store.file), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("Mochi").path))
        }
    }
    func testEmptyDestinationMigratesButUnrelatedContentsArePreserved() throws {
        let parent = temporary()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = LibraryStore(root: parent.appendingPathComponent(AppIdentity.legacyDataDirectory))
        var library = Library()
        library.conversations = [Conversation(title: "Existing")]
        try store.save(library)
        let new = parent.appendingPathComponent("Mochi")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let migrated = try AppIdentity.prepareDataDirectory(in: parent)
        XCTAssertEqual(try LibraryStore(root: migrated).load().conversations[0].title, "Existing")
        try FileManager.default.removeItem(at: new.appendingPathComponent("library.json"))
        try Data([1]).write(to: new.appendingPathComponent("other-data"))
        XCTAssertThrowsError(try AppIdentity.prepareDataDirectory(in: parent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("other-data").path))
    }
    private func temporary() -> URL { TestScratch.folder() }
}

extension DataFolderTests {
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

    func testStrayFilesWithoutAnOlderLibraryNeverBlockStartup() throws {
        let parent = temporary()
        let mochi = parent.appendingPathComponent(AppIdentity.name)
        try FileManager.default.createDirectory(at: mochi, withIntermediateDirectories: true)
        for name in ["builtin-preview.wav", ".DS_Store", ".library-write-\(UUID()).json"] {
            try Data([1]).write(to: mochi.appendingPathComponent(name))
        }
        XCTAssertEqual(try AppIdentity.prepareDataDirectory(in: parent).path, mochi.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mochi.appendingPathComponent("builtin-preview.wav").path))
    }

    func testStrayFilesBlockOnlyAMigrationAndTheMessageSaysWhy() throws {
        let parent = temporary()
        let mochi = parent.appendingPathComponent(AppIdentity.name)
        var library = Library()
        library.conversations = [Conversation(title: "Old")]
        try LibraryStore(root: parent.appendingPathComponent(AppIdentity.legacyDataDirectory)).save(library)
        try FileManager.default.createDirectory(at: mochi, withIntermediateDirectories: true)
        try Data([1]).write(to: mochi.appendingPathComponent("builtin-preview.wav"))
        XCTAssertThrowsError(try AppIdentity.prepareDataDirectory(in: parent)) { error in
            XCTAssertTrue(AppFailure.message(for: error, fallback: "").contains(AppIdentity.legacyDataDirectory))
        }
        XCTAssertEqual(AppIdentity.recoveryFolder(in: parent).path, mochi.path)
    }

    func testRecoveryFolderIsTheOlderLibraryWhenTheMochiFolderIsEmpty() throws {
        let parent = temporary()
        let legacy = parent.appendingPathComponent(AppIdentity.legacyDataDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertEqual(AppIdentity.recoveryFolder(in: parent).path, legacy.path)
    }

    func testMigrationIsNeededOnlyForAnOlderLibraryWithoutANewOne() throws {
        let support = try folder()
        XCTAssertFalse(AppIdentity.needsMigration(in: support))
        try LibraryStore(root: support.appendingPathComponent(AppIdentity.legacyDataDirectory)).save(Library())
        XCTAssertTrue(AppIdentity.needsMigration(in: support))
        try LibraryStore(root: support.appendingPathComponent(AppIdentity.name)).save(Library())
        XCTAssertFalse(AppIdentity.needsMigration(in: support))
    }

    func testInterruptedMigrationCopiesAreSweptButFreshOnesAreNot() throws {
        let support = try folder()
        let stale = support.appendingPathComponent(".mochi-migration-old")
        let fresh = support.appendingPathComponent(".mochi-migration-new")
        let unrelated = support.appendingPathComponent("Enjoy Myself")
        for url in [stale, fresh, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: stale.path)
        AppIdentity.sweepStaleMigrations(in: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func folder() throws -> URL {
        let url = TestScratch.folder("mochi-files")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
