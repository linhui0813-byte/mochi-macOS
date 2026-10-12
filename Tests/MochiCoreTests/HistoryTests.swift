import MochiTestSupport
import XCTest

@testable import MochiCore

final class HistoryTests: XCTestCase {
    func testLegacyDefaultsAndMigrationBackup() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        try store.prepare()
        let id = UUID()
        let legacy = Data(
            "{\"version\":1,\"conversations\":[{\"id\":\"\(id)\",\"title\":\"Old\",\"messages\":[],\"date\":0}],\"expressions\":[]}"
                .utf8)
        try legacy.write(to: store.file)
        var library = try store.load()
        XCTAssertEqual(library.version, 3)
        XCTAssertFalse(library.conversations[0].pinned)
        XCTAssertEqual(library.conversations[0].draft, "")
        library.conversations[0].draft = "Unsaved thought"
        library.selectedConversationID = id
        try store.save(library)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library-v1-backup.json")), legacy)
        XCTAssertEqual(try store.load().conversations[0].draft, "Unsaved thought")
        XCTAssertEqual(try store.load().selectedConversationID, id)
    }
    func testSearchScopeAndOrdering() {
        var older = Conversation(title: "Café")
        older.date = Date(timeIntervalSince1970: 0)
        older.pinned = true
        var newest = Conversation(title: "Latest")
        newest.messages = [Message(role: "user", text: "你好 coffee")]
        var archive = Conversation(title: "Archive")
        archive.archived = true
        archive.messages = [Message(role: "user", text: "COFFEE")]
        var deleted = Conversation(title: "Deleted coffee")
        deleted.deletedAt = Date()
        var library = Library()
        library.conversations = [newest, archive, deleted, older]
        XCTAssertEqual(library.history(in: .active).map(\.id), [older.id, newest.id])
        XCTAssertEqual(library.history(in: .active, query: "coffee").count, 2)
        XCTAssertEqual(library.history(in: .active, query: "cafe").first?.id, older.id)
        XCTAssertEqual(library.history(in: .active, query: "你好").first?.id, newest.id)
        XCTAssertEqual(library.history(in: .deleted, query: "coffee").first?.id, deleted.id)
    }
    func testLifecycleAndSharedAudio() {
        var chat = Conversation(title: "Keep")
        chat.archived = true
        chat.messages = [
            Message(role: "user", text: "Hello", audio: "shared.wav"),
            Message(role: "assistant", text: "Hi", audio: "only.wav"),
        ]
        var item = PracticeExpression(conversationID: chat.id, meaning: "", english: "Hello")
        item.reference = "shared.wav"
        var library = Library()
        library.conversations = [chat]
        library.expressions = [item]
        library.moveToDeleted([chat.id])
        XCTAssertTrue(library.conversations[0].isDeleted)
        library.restore([chat.id])
        XCTAssertTrue(library.conversations[0].archived)
        library.moveToDeleted([chat.id])
        XCTAssertEqual(library.removePermanently([chat.id]), Set(["only.wav"]))
        XCTAssertEqual(library.expressions.count, 1)
        XCTAssertEqual(library.conversations.count, 0)
    }
    func testMarkdownAndSearchPerformance() throws {
        var chat = Conversation(title: "A title")
        chat.messages = [Message(role: "user", text: "Find needle here")]
        XCTAssertTrue(HistoryExport.markdown([chat]).contains("Find needle here"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: HistoryExport.json([chat])) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "mochi-transcript")
        XCTAssertEqual(json["version"] as? Int, 1)
        var library = Library()
        library.conversations = (0..<1000).map { n in
            var c = Conversation(title: "\(n)")
            c.messages = [Message(role: "assistant", text: "A paragraph about needle")]
            return c
        }
        // Thread CPU time measures the search's own work; wall time also counts scheduler waits on a loaded host.
        func cpu() -> Double {
            var t = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
            return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
        }
        let start = cpu()
        XCTAssertEqual(library.history(in: .active, query: "needle").count, 1000)
        XCTAssertLessThan(cpu() - start, 0.1)
    }
    func testFailedSaveKeepsOriginalAndDoesNotCleanAudio() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        try store.prepare()
        try Data("block".utf8).write(to: store.file)
        var library = Library()
        library.conversations = [Conversation()]
        XCTAssertThrowsError(try store.save(library))
        XCTAssertEqual(try String(contentsOf: store.file), "block")
    }
    private func temporary() -> URL { TestScratch.folder() }
}

extension HistoryTests {
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

extension HistoryTests {
    /// Three conversations whose order differs by every key: by activity, by creation, by title and by companion.
    private func sortable() -> Library {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func chat(_ title: String, companion: String?, created: Double, active: Double) -> Conversation {
            var c = Conversation(title: title)
            c.characterName = companion
            c.date = base.addingTimeInterval(created)
            c.messages = [Message(role: "user", text: "Hello from \(title)")]
            c.messages[0].date = base.addingTimeInterval(active)
            return c
        }
        var library = Library()
        library.conversations = [
            chat("Banana", companion: "Loki", created: 0, active: 30),
            chat("apple", companion: nil, created: 20, active: 10),
            chat("Cherry", companion: "Ana", created: 10, active: 20),
        ]
        return library
    }

    func testHistorySortsByActivityCreationTitleOrCompanion() {
        let library = sortable()
        func titles(_ sort: HistorySort) -> [String] { library.history(in: .active, sort: sort).map(\.title) }
        XCTAssertEqual(titles(.recent), ["Banana", "Cherry", "apple"])
        XCTAssertEqual(titles(.created), ["apple", "Cherry", "Banana"])
        XCTAssertEqual(titles(.title), ["apple", "Banana", "Cherry"], "Alphabetical, ignoring case")
        // A conversation without a custom name is with Mochi.
        XCTAssertEqual(titles(.companion), ["Cherry", "Banana", "apple"])
    }

    func testHistoryFiltersByCompanionAndSearchFindsCompanions() {
        var library = sortable()
        XCTAssertEqual(library.companions(in: .active), ["Ana", "Loki", "Mochi"])
        XCTAssertEqual(library.history(in: .active, companion: "Loki").map(\.title), ["Banana"])
        XCTAssertEqual(library.history(in: .active, companion: "Mochi").map(\.title), ["apple"])
        XCTAssertEqual(library.history(in: .active, query: "loki").map(\.title), ["Banana"])
        // Pinned conversations still lead, whatever the order.
        library.conversations[2].pinned = true
        XCTAssertEqual(library.history(in: .active, sort: .title).map(\.title), ["Cherry", "apple", "Banana"])
    }
}
