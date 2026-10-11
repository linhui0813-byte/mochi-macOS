import Foundation

/// Find in the open conversation: the query, the messages it matches and which match is current.
/// A new query starts from the first match; a changed conversation keeps the current match when it still matches.
@MainActor @Observable final class ConversationFind {
    var query = "" { didSet { refresh(reset: true) } }
    var isOpen = false
    /// Incremented to move keyboard focus to the search field.
    var focusRequest = 0
    private(set) var matchID: UUID?
    private(set) var matchIDs: [UUID] = []
    private(set) var matchSet: Set<UUID> = []
    /// The messages of the open conversation that a query matches, in order.
    @ObservationIgnored var matching: (String) -> [UUID] = { _ in [] }
    var matchIndex: Int { matchID.flatMap { matchIDs.firstIndex(of: $0) } ?? 0 }
    func refresh(reset: Bool = false) {
        let previousIndex = matchIndex
        let ids = matching(query)
        matchIDs = ids
        matchSet = Set(ids)
        if reset || matchID == nil || !matchSet.contains(matchID!) {
            matchID = ids.isEmpty ? nil : ids[min(reset ? 0 : previousIndex, ids.count - 1)]
        }
    }
    func open() {
        isOpen = true
        focusRequest += 1
    }
    func close() {
        query = ""
        isOpen = false
    }
    func move(_ direction: Int) {
        let count = matchIDs.count
        guard count > 0 else {
            matchID = nil
            return
        }
        matchID = matchIDs[((matchIndex + direction) % count + count) % count]
    }
}
