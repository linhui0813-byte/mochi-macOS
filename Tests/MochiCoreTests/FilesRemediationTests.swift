import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

final class FilesRemediationTests: XCTestCase {
    private func folder() throws -> URL {
        let url = TestScratch.folder("mochi-files")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func age(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -days * 86400)], ofItemAtPath: url.path)
    }

    // MARK: Backup merge (M15, M8)

    func testMergeRemapsAttemptsAndReferences() throws {
        let package = try folder()
        let root = try folder()
        for name in ["ref.wav", "try1.wav", "try2.wav"] {
            try Data([1]).write(to: package.appendingPathComponent(name))
        }
        var library = Library()
        let chat = Conversation()
        library.conversations = [chat]
        var item = PracticeExpression(conversationID: chat.id, meaning: "", english: "Hello")
        item.reference = "ref.wav"
        item.attempts = [Attempt(file: "try1.wav"), Attempt(file: "try2.wav")]
        library.expressions = [item]
        var local = Library()
        XCTAssertEqual(try LibraryBackup.merge(library, from: package, into: &local, root: root), 1)
        let merged = try XCTUnwrap(local.expressions.first)
        let names = [merged.reference!] + merged.attempts.map(\.file)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("import-") })
        XCTAssertEqual(Set(names).count, 3)
        for name in names {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }
    func testFailedCopyLeavesNothingBehind() throws {
        let package = try folder()
        let root = try folder()
        try Data([1]).write(to: package.appendingPathComponent("good.wav"))
        try Data([1]).write(to: package.appendingPathComponent("locked.wav"))
        XCTAssertEqual(chmod(package.appendingPathComponent("locked.wav").path, 0), 0)
        defer { chmod(package.appendingPathComponent("locked.wav").path, 0o600) }
        var library = Library()
        var chat = Conversation()
        chat.messages = [
            Message(role: "user", text: "", audio: "good.wav"), Message(role: "user", text: "", audio: "locked.wav"),
        ]
        library.conversations = [chat]
        var local = Library()
        XCTAssertThrowsError(try LibraryBackup.merge(library, from: package, into: &local, root: root))
        XCTAssertTrue(local.conversations.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testPreparedImportSkipsItemsAddedMeanwhile() throws {
        let package = try folder()
        let root = try folder()
        var library = Library()
        let chat = Conversation(title: "Shared")
        library.conversations = [chat]
        let prepared = try LibraryBackup.prepareMerge(library, from: package, into: Library(), root: root)
        var local = Library()
        local.conversations = [chat]
        XCTAssertEqual(try LibraryBackup.apply(prepared, to: &local), 0)
        XCTAssertEqual(local.conversations.count, 1)
    }

    // MARK: Generated audio cleanup (M9)

    func testUnusedGeneratedAudioIsRemovedOnlyAfterItsCacheLifetime() throws {
        let root = try folder()
        let store = LibraryStore(root: root)
        let hash = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        // Old and unreferenced caches are removed; a recent cache is kept; an abandoned take goes at once;
        // names Mochi does not generate are never touched.
        let oldCaches = ["builtin-\(hash).wav", "elevenlabs-\(hash).mp3", "import-\(UUID().uuidString).m4a"]
        let recentCache = "builtin-\(other).wav"
        let abandonedTake = "recording-\(UUID().uuidString).wav"
        let foreign = ["builtin-short.wav", "notes.txt", "reference-old.mp3"]
        let files = oldCaches + [recentCache, abandonedTake] + foreign
        for name in files { try Data([1]).write(to: root.appendingPathComponent(name)) }
        for name in oldCaches + foreign { try age(root.appendingPathComponent(name), days: 8) }
        let referenced = "builtin-\(String(repeating:"c",count:64)).wav"
        try Data([1]).write(to: root.appendingPathComponent(referenced))
        try age(root.appendingPathComponent(referenced), days: 30)
        var library = Library()
        var chat = Conversation()
        chat.messages = [Message(role: "assistant", text: "Hi", audio: referenced)]
        library.conversations = [chat]
        try store.cleanupOrphanedAudio(library)
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(
            remaining, Set(["builtin-\(other).wav", "builtin-short.wav", "notes.txt", "reference-old.mp3", referenced]))
    }
    func testUsingACachedExampleKeepsItFromCleanup() async throws {
        let root = try folder()
        let service = RealtimeService()
        let cached = root.appendingPathComponent(
            ReferenceSpeech.cacheName(text: "Hi.", model: service.model, voice: service.voice))
        try Data([1]).write(to: cached)
        try age(cached, days: 8)
        _ = try await service.referenceAudio(text: "Hi.", root: root, force: false) { _ in
            throw AppFailure("must not regenerate")
        }
        try LibraryStore(root: root).cleanupOrphanedAudio(Library())
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
    }

    // MARK: Interrupted migrations (M8)

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
    func testMigrationIsNeededOnlyForAnOlderLibraryWithoutANewOne() throws {
        let support = try folder()
        XCTAssertFalse(AppIdentity.needsMigration(in: support))
        try LibraryStore(root: support.appendingPathComponent(AppIdentity.legacyDataDirectory)).save(Library())
        XCTAssertTrue(AppIdentity.needsMigration(in: support))
        try LibraryStore(root: support.appendingPathComponent(AppIdentity.name)).save(Library())
        XCTAssertFalse(AppIdentity.needsMigration(in: support))
    }

    // MARK: Names and pitch (L4, L5)

    func testRealNamesWithJoinersAreAcceptedAndSpoofingIsNot() {
        for name in ["Teacher 👩‍🏫", "می‌خواهم", "Renée", "❤️ Mochi"] {
            XCTAssertNoThrow(try ConversationTemplate.validateName(name), name)
        }
        for name in ["Line\nbreak", "Nul\u{0}", "Tab\tbed", "Evil\u{202E}txt.exe", "Iso\u{2066}late"] {
            XCTAssertThrowsError(try ConversationTemplate.validateName(name), name)
        }
    }
    func testDegenerateSampleRatesAndCancellationReturnNoPitch() async {
        XCTAssertEqual(PitchAnalyzer.analyze(samples: Array(repeating: 0.1, count: 2000), sampleRate: 120).count, 0)
        XCTAssertEqual(PitchAnalyzer.analyze(samples: Array(repeating: 0.1, count: 2000), sampleRate: 60).count, 0)
        let tone = (0..<48000).map { Float(sin(2 * Double.pi * 200 * Double($0) / 24000)) * 0.5 }
        let task = Task.detached { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return PitchAnalyzer.analyze(samples: tone, sampleRate: 24000).count
        }
        let count = await task.value
        XCTAssertEqual(count, 0)
    }
}

extension FilesRemediationTests {
    /// The sidebar badges count without sorting; they must agree with the lists they label.
    func testHistoryCountsMatchTheListedConversations() {
        var library = Library()
        library.conversations = (0..<30).map { n in
            var chat = Conversation(title: "\(n)")
            chat.archived = n % 3 == 0
            if n % 5 == 0 { chat.deletedAt = Date(timeIntervalSince1970: Double(n)) }
            return chat
        }
        for scope in HistoryScope.allCases {
            XCTAssertEqual(library.count(in: scope), library.history(in: scope).count, scope.rawValue)
        }
    }
}
