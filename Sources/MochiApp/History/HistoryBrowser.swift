import Foundation
import MochiCore

/// The history list and its manager: which conversations are listed, and the edit in progress there.
struct HistoryBrowser {
    var scope: HistoryScope = .active
    var query = ""
    /// Only conversations with this character are listed; nil lists every character.
    var character: String?
    var searchOpen = false
    /// Incremented to move keyboard focus to the history search field.
    var searchFocusRequest = 0
    var managerOpen = false
    var renameID: UUID?
    var permanentDeleteIDs: Set<UUID> = []
    /// The outcome of the last history action, shown in the manager.
    var feedback: String?
    /// The manager, a rename or a permanent deletion is open.
    var isEditing: Bool { managerOpen || renameID != nil || !permanentDeleteIDs.isEmpty }
}
