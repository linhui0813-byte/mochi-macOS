import Darwin
import Foundation
import MochiKernel

public enum Mode: String, Codable { case conversation, practice }
public enum Activity: String { case idle, generating, playing, recording, requestingPermission }
public enum AudioOwner { case none, conversation, practice, playback }
public struct TurnMachine {
    public private(set) var mode: Mode = .conversation
    public private(set) var activity: Activity = .idle
    public private(set) var epoch = UUID()
    public var owner: AudioOwner {
        activity == .playing
            ? .playback : activity == .recording ? (mode == .practice ? .practice : .conversation) : .none
    }
    public init() {}
    @discardableResult public mutating func begin(_ activity: Activity) -> UUID {
        epoch = UUID()
        self.activity = activity
        return epoch
    }
    public mutating func finish(_ token: UUID) -> Bool {
        guard token == epoch else { return false }
        activity = .idle
        return true
    }
    public mutating func pause() {
        mode = .practice
        _ = begin(.idle)
    }
    public mutating func resume() {
        mode = .conversation
        _ = begin(.idle)
    }
    public mutating func stop() { _ = begin(.idle) }
    public mutating func startRecording() -> Bool {
        guard activity == .idle else { return false }
        _ = begin(.recording)
        return true
    }
}
public struct Message: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var role: String
    public var text: String
    public var audio: String?
    public var speakerName: String?
    public var date = Date()
    public var transcriptionState: TranscriptionState?
    public var transcriptionError: String?
    public init(role: String, text: String, audio: String? = nil, speakerName: String? = nil) {
        self.role = role
        self.text = text
        self.audio = audio
        self.speakerName = speakerName
    }
    public var contextText: String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !(role == "user" && audio != nil && Self.legacyLabels.contains(text))
        else { return nil }
        return text
    }
    public var displayText: String {
        contextText ?? (role == "user" && audio != nil ? String(localized: "Voice recording") : text)
    }
    private static let legacyLabels = ["Voice message (transcript unavailable)", "Voice message · awaiting transcript"]
    private enum CodingKeys: String, CodingKey {
        case id, role, text, audio, date, transcriptionState, transcriptionError, speakerName
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        audio = try c.decodeIfPresent(String.self, forKey: .audio)
        speakerName = try c.decodeIfPresent(String.self, forKey: .speakerName)
        date = try c.decode(Date.self, forKey: .date)
        transcriptionState = try c.decodeIfPresent(TranscriptionState.self, forKey: .transcriptionState)
        transcriptionError = try c.decodeIfPresent(String.self, forKey: .transcriptionError)
        if role == "user", audio != nil, Self.legacyLabels.contains(text) {
            transcriptionState = text.contains("awaiting") ? .interrupted : .failed
            text = ""
        }
    }
}
public struct Conversation: Codable, Identifiable {
    public var id = UUID()
    public var title: String
    public var messages: [Message] = []
    public var date = Date()
    public var pinned = false
    public var archived = false
    public var deletedAt: Date?
    public var wasArchivedBeforeDeletion = false
    public var customTitle = false
    public var draft = ""
    public var helpDraft: HelpDraft?
    public var instructions = ""
    public var preferences = ConversationPreferences()
    public var characterName: String?
    public var sourceTemplateID: UUID?
    public var sourceTemplateRevision: String?
    public var characterNameNeedsReview: Bool {
        characterName != nil && (try? ConversationTemplate.validateName(characterName)) == nil
    }
    public var displayCharacterName: String { characterNameNeedsReview ? "Companion" : characterName ?? "Mochi" }
    public var isPristine: Bool {
        messages.isEmpty && !customTitle && instructions.isEmpty && draft.isEmpty && helpDraft == nil
            && preferences == ConversationPreferences() && characterName == nil && sourceTemplateID == nil
            && sourceTemplateRevision == nil
    }
    public var voiceIntroduced = false
    public var isDeleted: Bool { deletedAt != nil }
    public var updatedAt: Date { messages.last?.date ?? date }
    /// The stored title of an untitled conversation. It stays English on disk: older libraries are read by comparing to it.
    public static let untitled = "A new conversation"
    public init(title: String = Conversation.untitled) { self.title = title }
    /// The title as shown: an untitled conversation reads in the app's language.
    public var displayTitle: String {
        !customTitle && title == Self.untitled ? String(localized: "A new conversation") : title
    }
    private enum CodingKeys: String, CodingKey {
        case id, title, messages, date, pinned, archived, deletedAt, wasArchivedBeforeDeletion, customTitle, draft,
            helpDraft, voiceIntroduced, instructions, preferences, characterName, sourceTemplateID,
            sourceTemplateRevision
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        messages = try c.decode([Message].self, forKey: .messages)
        date = try c.decode(Date.self, forKey: .date)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        wasArchivedBeforeDeletion = try c.decodeIfPresent(Bool.self, forKey: .wasArchivedBeforeDeletion) ?? false
        customTitle =
            try c.decodeIfPresent(Bool.self, forKey: .customTitle)
            ?? (title != Self.untitled && messages.isEmpty)
        draft = try c.decodeIfPresent(String.self, forKey: .draft) ?? ""
        helpDraft = try c.decodeIfPresent(HelpDraft.self, forKey: .helpDraft)
        characterName = try c.decodeIfPresent(String.self, forKey: .characterName)
        sourceTemplateID = try c.decodeIfPresent(UUID.self, forKey: .sourceTemplateID)
        sourceTemplateRevision = try c.decodeIfPresent(String.self, forKey: .sourceTemplateRevision)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        preferences =
            try c.decodeIfPresent(ConversationPreferences.self, forKey: .preferences) ?? ConversationPreferences()
        voiceIntroduced =
            try c.decodeIfPresent(Bool.self, forKey: .voiceIntroduced)
            ?? messages.contains { $0.role == "user" && $0.audio != nil }
    }
}
public struct Attempt: Codable, Identifiable {
    public var id = UUID()
    public var file: String
    public var date = Date()
    public init(file: String) { self.file = file }
}
public struct PracticeExpression: Codable, Identifiable {
    public var id = UUID()
    public var conversationID: UUID
    public var meaning: String
    public var english: String
    public var reference: String?
    public var referenceKind: String = "Your voice"
    public var attempts: [Attempt] = []
    public var date = Date()
    public init(conversationID: UUID, meaning: String, english: String) {
        self.conversationID = conversationID
        self.meaning = meaning
        self.english = english
    }
}
public struct Library: Codable {
    public var conversationTemplates: [ConversationTemplate] = []
    public var version = 3
    public var selectedConversationID: UUID?
    public var conversations: [Conversation] = []
    public var expressions: [PracticeExpression] = []
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case version, selectedConversationID, conversations, expressions, conversationTemplates
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        selectedConversationID = try c.decodeIfPresent(UUID.self, forKey: .selectedConversationID)
        conversations = try c.decode([Conversation].self, forKey: .conversations)
        expressions = try c.decode([PracticeExpression].self, forKey: .expressions)
        conversationTemplates = try c.decodeIfPresent([ConversationTemplate].self, forKey: .conversationTemplates) ?? []
    }
}
extension Library {
    /// Transcriptions recorded as pending have no running job once the library is read back from disk.
    public mutating func interruptPendingTranscriptions() {
        for ci in conversations.indices {
            for mi in conversations[ci].messages.indices
            where conversations[ci].messages[mi].transcriptionState == .pending {
                conversations[ci].messages[mi].transcriptionState = .interrupted
            }
        }
    }
}
/// Marks a library that failed validation while still in memory: a programming error, never user data.
public struct LibraryInvariantViolation: Error { public let reason: String }
public final class LibraryStore {
    public let root: URL
    public var file: URL { root.appendingPathComponent("library.json") }
    /// The last library this store replaced, kept as a hard link so it costs no copy.
    public var previousFile: URL { root.appendingPathComponent("library.previous.json") }
    public static let reservedNames: Set<String> = [
        "library.json", "library.previous.json", "library-v1-backup.json", "library-before-help-transcription.json",
        "library-before-conversation-instructions.json",
    ]
    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: timespec
        static func == (a: Self, b: Self) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec
                && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }
    /// State of the file this store last read or wrote. While the file on disk still matches it,
    /// saving needs no re-read: migration backups were settled when it was first written.
    private struct Known {
        let identity: FileIdentity
        let version: Int
        var instructionsBackup: Bool
        var featureBackup: Bool
    }
    private var known: Known?
    public init(root: URL) { self.root = root }
    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func identity(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, size: info.st_size, modified: info.st_mtimespec)
    }
    private func remember(_ identity: FileIdentity?, version: Int) {
        guard let identity else {
            known = nil
            return
        }
        known = Known(
            identity: identity, version: version,
            instructionsBackup: FileManager.default.fileExists(
                atPath: root.appendingPathComponent("library-before-conversation-instructions.json").path),
            featureBackup: FileManager.default.fileExists(
                atPath: root.appendingPathComponent("library-before-help-transcription.json").path))
    }
    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: file.path) else {
            known = nil
            return Library()
        }
        let before = identity(file)
        let data = try Data(contentsOf: file)
        var library = try JSONDecoder().decode(Library.self, from: data)
        guard (1...3).contains(library.version) else {
            throw AppFailure(
                "This library was created by a newer version of Mochi. Update Mochi to open it; your data has not been changed."
            )
        }
        try library.validate()
        remember(before == identity(file) ? before : nil, version: library.version)
        library.interruptPendingTranscriptions()
        library.version = 3
        return library
    }
    /// Loads the copy kept before the most recent save, for recovery when `library.json` is unreadable.
    public func loadPrevious() throws -> Library {
        guard identity(previousFile) != nil else { throw AppFailure("No earlier copy of the library is available.") }
        var library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: previousFile))
        guard (1...3).contains(library.version) else {
            throw AppFailure("The earlier copy was created by a newer version of Mochi.")
        }
        try library.validate()
        library.interruptPendingTranscriptions()
        library.version = 3
        return library
    }
    /// Keeps an unreadable library under a second name (never deleting it) and atomically reinstates the earlier copy,
    /// so `library.json` always names one of the two.
    public func restorePrevious() throws -> Library {
        let library = try loadPrevious()
        var aside: URL?
        if FileManager.default.fileExists(atPath: file.path) {
            let url = root.appendingPathComponent(
                "library-unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
            guard Darwin.link(file.path, url.path) == 0 else {
                throw AppFailure(
                    "The unreadable library could not be set aside, so nothing was restored.",
                    underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
            aside = url
        }
        known = nil
        do { try write(library, replacingUnreadable: true) } catch {
            // `library.json` still names the unreadable file, so the extra name is not needed.
            if let aside { unlink(aside.path) }
            throw error
        }
        return library
    }
    /// Folders of hard links that keep an export's recordings; one left by a force quit is removed at cleanup.
    public static let exportStagingPrefix = ".export-"
    /// How long an unreferenced generated example or preview stays cached after its last use.
    public static let cacheLifetime: TimeInterval = 7 * 24 * 3600
    /// Removes audio Mochi created that nothing references: abandoned recordings and replies at once,
    /// generated examples, previews and replaced imports once unused for `cacheLifetime`. Other files are never touched.
    public func cleanupOrphanedAudio(_ library: Library, now: Date = Date()) throws {
        try library.validate()
        // The earlier copy can be reinstated later, so its recordings stay too.
        let referenced = library.referencedAudio.union((try? loadPrevious())?.referencedAudio ?? [])
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey,
        ]
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) {
            let name = url.lastPathComponent
            if name.hasPrefix(Self.exportStagingPrefix) {
                let values = try url.resourceValues(forKeys: keys)
                if values.isDirectory == true, values.isSymbolicLink != true {
                    try FileManager.default.removeItem(at: url)
                }
                continue
            }
            guard !referenced.contains(name), let kind = Self.generatedAudio(name) else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if kind == .cache, now.timeIntervalSince(values.contentModificationDate ?? now) < Self.cacheLifetime {
                continue
            }
            try FileManager.default.removeItem(at: url)
        }
    }
    enum GeneratedAudio { case session, cache }
    /// Classifies names Mochi itself generates; anything else is not Mochi's to delete.
    static func generatedAudio(_ name: String) -> GeneratedAudio? {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        func suffix(after prefix: String) -> String? {
            stem.hasPrefix(prefix) ? String(stem.dropFirst(prefix.count)) : nil
        }
        if ext == "wav", let id = suffix(after: "recording-") ?? suffix(after: "reply-"), UUID(uuidString: id) != nil {
            return .session
        }
        if let id = suffix(after: "import-"), UUID(uuidString: id) != nil, !ext.isEmpty { return .cache }
        for (prefix, expected) in [("builtin-", "wav"), ("elevenlabs-", "mp3")] {
            if ext == expected, let hash = suffix(after: prefix), hash.count == 64, hash.allSatisfy(\.isHexDigit) {
                return .cache
            }
        }
        return nil
    }
    public func save(_ library: Library) throws { try write(library, replacingUnreadable: false) }
    /// `replacingUnreadable` installs over a file already kept elsewhere: it is neither read nor kept as the earlier copy.
    private func write(_ library: Library, replacingUnreadable: Bool) throws {
        try prepare()
        guard (1...3).contains(library.version) else { throw AppFailure("Unsupported library version.") }
        do { try library.validate() } catch {
            throw AppFailure(
                "Mochi found an inconsistency in your library and did not save it. Your saved library is unchanged.",
                underlying: LibraryInvariantViolation(
                    reason: (error as? AppFailure)?.message ?? String(describing: error)))
        }
        var library = library
        library.version = 3
        let usesHelpOrTranscription = library.conversations.contains(where: {
            $0.helpDraft != nil || $0.messages.contains(where: { $0.transcriptionState != nil })
        })
        let current = replacingUnreadable ? nil : identity(file)
        let settled =
            known.map {
                $0.identity == current && $0.version == 3 && $0.instructionsBackup
                    && ($0.featureBackup || !usesHelpOrTranscription)
            } ?? false
        if current != nil && !settled { try settleMigrationBackups(usesHelpOrTranscription: usesHelpOrTranscription) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        let staging = root.appendingPathComponent(".library-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: staging) }
        try writeDurably(data, to: staging)
        if current != nil { keepPrevious() }
        guard Darwin.rename(staging.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        remember(identity(file), version: 3)
    }
    /// Re-reads a library that Mochi has not written itself and preserves pre-upgrade copies before replacing it.
    private func settleMigrationBackups(usesHelpOrTranscription: Bool) throws {
        let original = try Data(contentsOf: file)
        let existing: Library
        do { existing = try JSONDecoder().decode(Library.self, from: original) } catch {
            throw AppFailure(
                "The library file was changed outside Mochi and cannot be read, so Mochi did not overwrite it.",
                underlying: error)
        }
        guard (1...3).contains(existing.version) else {
            throw AppFailure(
                "The library file on disk was written by a newer version of Mochi, so Mochi did not overwrite it.")
        }
        if existing.version < 3 {
            let base = root.appendingPathComponent("library-before-character-templates-v3.json")
            let backupExists = FileManager.default.fileExists(atPath: base.path)
            let backupMatches = backupExists ? try Data(contentsOf: base) == original : false
            if !backupMatches {
                let destination =
                    FileManager.default.fileExists(atPath: base.path)
                    ? root.appendingPathComponent(
                        "library-before-character-templates-v3-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json"
                    ) : base
                try writeNewPrivateFile(original, to: destination)
            }
        }
        let instructionsBackup = root.appendingPathComponent("library-before-conversation-instructions.json")
        if !FileManager.default.fileExists(atPath: instructionsBackup.path) {
            try writeNewPrivateFile(original, to: instructionsBackup)
        }
        let featureBackup = root.appendingPathComponent("library-before-help-transcription.json")
        if usesHelpOrTranscription, !FileManager.default.fileExists(atPath: featureBackup.path) {
            try writeNewPrivateFile(original, to: featureBackup)
        }
        let backup = root.appendingPathComponent("library-v1-backup.json")
        if existing.version == 1 && !FileManager.default.fileExists(atPath: backup.path) {
            try writeNewPrivateFile(original, to: backup)
        }
    }
    /// Keeps the file about to be replaced as `library.previous.json`. Losing this copy never blocks a save.
    private func keepPrevious() {
        let staging = root.appendingPathComponent(".library-previous-\(UUID().uuidString).json")
        guard Darwin.link(file.path, staging.path) == 0 else {
            MochiLog.failure(
                MochiLog.library, "Keep previous library", POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                level: .info)
            return
        }
        if Darwin.rename(staging.path, previousFile.path) != 0 {
            MochiLog.failure(
                MochiLog.library, "Replace previous library", POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                level: .info)
            unlink(staging.path)
        }
    }
    /// The data reaches stable storage before the rename, so `library.json` is never a name for incomplete bytes.
    private func writeDurably(_ data: Data, to destination: URL) throws {
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        if fcntl(descriptor, F_FULLFSYNC) != 0 { try handle.synchronize() }
        try handle.close()
    }
    /// Creates a complete 0600 copy that never replaces an existing file, so a failed write cannot leave a partial or briefly readable backup under the final name.
    private func writeNewPrivateFile(_ data: Data, to destination: URL) throws {
        let staging = root.appendingPathComponent(".backup-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: staging) }
        try writeDurably(data, to: staging)
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
