import MochiCore
import XCTest

@testable import MochiApp

final class AuditFixG6Tests: XCTestCase {
    /// An active-collection search also lists archived conversations, so bulk actions follow each one's state.
    @MainActor func testSelectionActionsSplitArchivedFromActiveConversations() {
        var library = Library()
        let active = Conversation(title: "Active")
        var archived = Conversation(title: "Archived")
        archived.archived = true
        var deleted = Conversation(title: "Deleted")
        deleted.deletedAt = Date()
        library.conversations = [active, archived, deleted]
        XCTAssertEqual(
            library.history(in: .active, query: "e").map(\.id).sorted { $0.uuidString < $1.uuidString },
            [active.id, archived.id].sorted { $0.uuidString < $1.uuidString })

        let mixed = HistorySelectionActions.targets([active.id, archived.id, deleted.id], in: library)
        XCTAssertEqual(mixed.archive, [active.id])
        XCTAssertEqual(mixed.restore, [archived.id])

        let onlyArchived = HistorySelectionActions.targets([archived.id], in: library)
        XCTAssertTrue(onlyArchived.archive.isEmpty)
        XCTAssertEqual(onlyArchived.restore, [archived.id])

        let none = HistorySelectionActions.targets([], in: library)
        XCTAssertTrue(none.archive.isEmpty && none.restore.isEmpty)
    }
}
