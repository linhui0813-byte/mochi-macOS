import Darwin
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
public enum LibraryBackup {
    public static func write(_ library: Library, from root: URL, to package: URL) throws {
        try library.validate()
        guard !FileManager.default.fileExists(atPath: package.path) else {
            throw AppFailure("Choose a new backup filename; an existing backup is never overwritten.")
        }
        for name in library.referencedAudio { try validateRegularFile(root.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Exclusive: a package that appeared since the check above is neither written into nor removed.
        guard mkdir(package.path, 0o700) == 0 else {
            if errno == EEXIST {
                throw AppFailure("Choose a new backup filename; an existing backup is never overwritten.")
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            var normalized = library
            normalized.version = 3
            try e.encode(normalized).write(to: package.appendingPathComponent("library.json"), options: .atomic)
            for name in library.referencedAudio {
                try FileManager.default.copyItem(
                    at: root.appendingPathComponent(name), to: package.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: package)
            throw error
        }
    }
    public static func read(_ package: URL) throws -> Library {
        try validateRegularFile(package.appendingPathComponent("library.json"))
        var library = try JSONDecoder().decode(
            Library.self, from: Data(contentsOf: package.appendingPathComponent("library.json")))
        guard (1...3).contains(library.version) else { throw AppFailure("This backup requires a newer app.") }
        try library.validate()
        for name in library.referencedAudio { try validateRegularFile(package.appendingPathComponent(name)) }
        library.version = 3
        return library
    }
    /// Items to import with their audio already copied under fresh names, ready to merge into the library as it is by then.
    public struct PreparedImport {
        public let additions: Library
        public let copied: [URL]
    }
    // Only missing IDs are imported; each imported audio name is remapped to avoid collisions.
    public static func merge(_ imported: Library, from package: URL, into local: inout Library, root: URL) throws -> Int
    {
        let prepared = try prepareMerge(imported, from: package, into: local, root: root)
        defer { discard(prepared, keeping: local) }
        return try apply(prepared, to: &local)
    }
    /// Adds the prepared items that are still missing. On a conflict `local` is unchanged.
    public static func apply(_ prepared: PreparedImport, to local: inout Library) throws -> Int {
        let chatIDs = Set(local.conversations.map(\.id))
        let expressionIDs = Set(local.expressions.map(\.id))
        let templateIDs = Set(local.conversationTemplates.map(\.id))
        let conversations = prepared.additions.conversations.filter { !chatIDs.contains($0.id) }
        let localMessageIDs = Set(local.conversations.flatMap(\.messages).map(\.id))
        guard !conversations.flatMap(\.messages).contains(where: { localMessageIDs.contains($0.id) }) else {
            throw AppFailure("Imported message IDs conflict with local history.")
        }
        var next = local
        next.conversations += conversations
        next.expressions += prepared.additions.expressions.filter { !expressionIDs.contains($0.id) }
        next.conversationTemplates += prepared.additions.conversationTemplates.filter { !templateIDs.contains($0.id) }
        next.version = 3
        try next.validate()
        local = next
        return conversations.count
    }
    /// Removes copied audio that `library` does not reference: all of it after an import was abandoned,
    /// and the audio of items skipped because they were added meanwhile after one was applied.
    public static func discard(_ prepared: PreparedImport, keeping library: Library) {
        let referenced = library.referencedAudio
        for url in prepared.copied where !referenced.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    /// Validates a backup against `local` and copies its new audio into `root`. Safe to run off the main thread.
    public static func prepareMerge(_ imported: Library, from package: URL, into local: Library, root: URL) throws
        -> PreparedImport
    {
        try imported.validate()
        for name in imported.referencedAudio { try validateRegularFile(package.appendingPathComponent(name)) }
        let chatIDs = Set(local.conversations.map(\.id))
        let expressionIDs = Set(local.expressions.map(\.id))
        var additions = Library()
        additions.conversations = imported.conversations.filter { !chatIDs.contains($0.id) }
        additions.expressions = imported.expressions.filter { !expressionIDs.contains($0.id) }
        let templateIDs = Set(local.conversationTemplates.map(\.id))
        additions.conversationTemplates = imported.conversationTemplates.filter { !templateIDs.contains($0.id) }
        let localMessageIDs = Set(local.conversations.flatMap(\.messages).map(\.id))
        guard !additions.conversations.flatMap(\.messages).contains(where: { localMessageIDs.contains($0.id) }) else {
            throw AppFailure("Imported message IDs conflict with local history.")
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var mapping: [String: String] = [:]
        var copied: [URL] = []
        do {
            for name in additions.referencedAudio {
                try Task.checkCancellation()
                let replacement = "import-\(UUID().uuidString).\(URL(fileURLWithPath:name).pathExtension)"
                let destination = root.appendingPathComponent(replacement)
                try FileManager.default.copyItem(at: package.appendingPathComponent(name), to: destination)
                copied.append(destination)
                mapping[name] = replacement
            }
            try remapAudio(in: &additions) { name in
                guard let replacement = mapping[name] else {
                    throw AppFailure("A backup recording could not be matched to its copy.")
                }
                return replacement
            }
            additions.interruptPendingTranscriptions()
            return PreparedImport(additions: additions, copied: copied)
        } catch {
            for url in copied { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
    /// Renames every recording `library` references.
    private static func remapAudio(in library: inout Library, _ mapped: (String) throws -> String) rethrows {
        for ci in library.conversations.indices {
            if let name = library.conversations[ci].helpDraft?.recording {
                library.conversations[ci].helpDraft?.recording = try mapped(name)
            }
            for mi in library.conversations[ci].messages.indices {
                if let name = library.conversations[ci].messages[mi].audio {
                    library.conversations[ci].messages[mi].audio = try mapped(name)
                }
            }
        }
        for i in library.expressions.indices {
            if let name = library.expressions[i].reference { library.expressions[i].reference = try mapped(name) }
            for ai in library.expressions[i].attempts.indices {
                library.expressions[i].attempts[ai].file = try mapped(library.expressions[i].attempts[ai].file)
            }
        }
    }
    private static func validateRegularFile(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true else {
            throw AppFailure("A backup recording is missing or is not a regular file.")
        }
    }
}
