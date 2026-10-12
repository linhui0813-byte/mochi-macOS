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
    /// Nothing has happened here yet. Its language is not counted: a new conversation starts in the user's default
    /// language, and reusing it takes the default again.
    public var isPristine: Bool {
        var settings = preferences
        settings.language = ConversationPreferences().language
        return messages.isEmpty && !customTitle && instructions.isEmpty && draft.isEmpty && helpDraft == nil
            && settings == ConversationPreferences() && characterName == nil && sourceTemplateID == nil
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
    /// The expression in the language practised; named for the English-only expressions saved before languages.
    public var english: String
    /// The language of `english`; nil for expressions saved before languages existed, which are English.
    public var language: ConversationLanguage?
    public var reference: String?
    public var referenceKind: String = "Your voice"
    public var attempts: [Attempt] = []
    public var date = Date()
    public init(conversationID: UUID, meaning: String, english: String, language: ConversationLanguage) {
        self.conversationID = conversationID
        self.meaning = meaning
        self.english = english
        self.language = language
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
public enum TranscriptionState: String, Codable { case pending, completed, failed, timedOut, interrupted }
public struct HelpDraft: Codable {
    public var meaning: String
    public var english: String
    public var recording: String?
    public var expressionID: UUID?
    public var clarification: String?
    public var transcriptReview: String?
    public init(meaning: String = "", english: String = "", recording: String? = nil, expressionID: UUID? = nil) {
        self.meaning = meaning
        self.english = english
        self.recording = recording
        self.expressionID = expressionID
    }
}
