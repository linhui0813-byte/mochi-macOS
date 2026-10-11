import Foundation
import MochiKernel

public enum HistoryScope: String, CaseIterable, Identifiable {
    case active, archived, deleted
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .active: return String(localized: "Conversations")
        case .archived: return String(localized: "Archived")
        case .deleted: return String(localized: "Recently Deleted")
        }
    }
    public var icon: String {
        switch self {
        case .active: return "bubble.left.and.bubble.right"
        case .archived: return "archivebox"
        case .deleted: return "trash"
        }
    }
}
extension Conversation {
    /// Matches the text a message shows as its content, so every search agrees on legacy voice placeholders.
    private func messageMatcher(_ query: String) -> ((Message) -> Bool)? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        return { $0.contextText?.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
    public func matchingMessage(_ query: String) -> Message? {
        messageMatcher(query).flatMap { messages.first(where: $0) }
    }
    public func matchingMessageIDs(_ query: String) -> [UUID] {
        messageMatcher(query).map { messages.filter($0).map(\.id) } ?? []
    }
    public func matches(_ query: String) -> Bool {
        title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || matchingMessage(query) != nil
    }
}
extension Library {
    /// The number of conversations `history(in:)` would list, without sorting them.
    public func count(in scope: HistoryScope) -> Int {
        conversations.reduce(0) { total, c in
            switch scope {
            case .active: return total + (!c.isDeleted && !c.archived ? 1 : 0)
            case .archived: return total + (!c.isDeleted && c.archived ? 1 : 0)
            case .deleted: return total + (c.isDeleted ? 1 : 0)
            }
        }
    }
    public func history(in scope: HistoryScope, query: String = "") -> [Conversation] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.filter { c in
            let included: Bool
            switch scope {
            case .active: included = !c.isDeleted && (!c.archived || !term.isEmpty)
            case .archived: included = !c.isDeleted && c.archived
            case .deleted: included = c.isDeleted
            }
            return included && (term.isEmpty || c.matches(term))
        }.sorted {
            if scope == .active && $0.pinned != $1.pinned { return $0.pinned }
            let lhs = scope == .deleted ? $0.deletedAt! : $0.updatedAt
            let rhs = scope == .deleted ? $1.deletedAt! : $1.updatedAt
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
        }
    }
    public mutating func moveToDeleted(_ ids: Set<UUID>, now: Date = Date()) {
        for i in conversations.indices where ids.contains(conversations[i].id) && !conversations[i].isDeleted {
            conversations[i].wasArchivedBeforeDeletion = conversations[i].archived
            conversations[i].deletedAt = now
        }
    }
    public mutating func restore(_ ids: Set<UUID>) {
        for i in conversations.indices where ids.contains(conversations[i].id) {
            if conversations[i].isDeleted {
                conversations[i].deletedAt = nil
                conversations[i].archived = conversations[i].wasArchivedBeforeDeletion
            } else {
                conversations[i].archived = false
            }
        }
    }
    public var referencedAudio: Set<String> {
        Set(
            conversations.flatMap { $0.messages.compactMap(\.audio) + [$0.helpDraft?.recording].compactMap { $0 } }
                + expressions.flatMap { [$0.reference].compactMap { $0 } + $0.attempts.map(\.file) })
    }
    @discardableResult public mutating func removePermanently(_ ids: Set<UUID>) -> Set<String> {
        let before = referencedAudio
        conversations.removeAll { ids.contains($0.id) && $0.isDeleted }
        if let selectedConversationID, !conversations.contains(where: { $0.id == selectedConversationID }) {
            self.selectedConversationID = nil
        }
        return before.subtracting(referencedAudio)
    }
    public func validate() throws {
        guard Set(conversations.map(\.id)).count == conversations.count,
            Set(expressions.map(\.id)).count == expressions.count
        else { throw AppFailure("The library contains duplicate IDs.") }
        guard Set(conversationTemplates.map(\.id)).count == conversationTemplates.count,
            !conversationTemplates.contains(where: {
                $0.isBuiltin || $0.revision.isEmpty || $0.revision.utf8.count > 200
            })
        else { throw AppFailure("The library contains invalid or duplicate template IDs/revisions.") }
        let attempts = expressions.flatMap(\.attempts)
        guard Set(attempts.map(\.id)).count == attempts.count else {
            throw AppFailure("The library contains duplicate attempt IDs.")
        }
        let messages = conversations.flatMap(\.messages)
        guard Set(messages.map(\.id)).count == messages.count else {
            throw AppFailure("The library contains duplicate message IDs.")
        }
        for chat in conversations { try chat.preferences.validate() }
        for name in referencedAudio {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                !name.hasPrefix("."), !name.hasPrefix("library-before-character-templates-v3"),
                !name.hasPrefix("library-unreadable-"), !LibraryStore.reservedNames.contains(name)
            else { throw AppFailure("The library contains an unsafe recording filename.") }
        }
    }
}
public enum HistoryExport {
    public static func markdown(_ chats: [Conversation]) -> String {
        chats.map { chat in
            "# \(chat.title.replacingOccurrences(of:"\n",with:" "))\n\n"
                + chat.messages.map { message in
                    "### \(message.role == "user" ? "You" : (message.speakerName ?? "Mochi")) · \(message.date.formatted(.iso8601))\n\n\(message.text)\n"
                        + (message.audio.map { "\nRecording: `\($0)` (audio is included only in a library backup).\n" }
                            ?? "")
                }.joined(separator: "\n")
        }.joined(separator: "\n---\n\n")
    }
    public static func json(_ chats: [Conversation]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        struct Transcript: Encodable {
            let format = "mochi-transcript"
            let version = 1
            let conversations: [Conversation]
        }
        return try e.encode(Transcript(conversations: chats))
    }
}
