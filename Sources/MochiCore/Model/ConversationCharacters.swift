import CryptoKit
import Foundation
import MochiKernel

/// A reusable companion: who Mochi is in a conversation. Picking one copies its name, personality and voice into a
/// conversation or template, which own them from then on; nothing records which character was picked, so editing
/// or deleting a character never changes an existing setup.
public struct ConversationCharacter: Codable, Identifiable, Equatable {
    public var id: UUID
    public var revision: String
    public var name: String
    public var description: String
    public var personality: String
    /// nil speaks in the conversation voice chosen in Settings.
    public var voice: String?
    public var createdAt: Date
    public var updatedAt: Date
    public init(name: String, description: String = "", personality: String = "", voice: String? = nil) {
        id = UUID()
        revision = UUID().uuidString
        self.name = name
        self.description = description
        self.personality = personality
        self.voice = voice
        createdAt = Date()
        updatedAt = createdAt
    }
    private enum CodingKeys: String, CodingKey {
        case id, revision, name, description, personality, voice, createdAt, updatedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        revision = try c.decode(String.self, forKey: .revision)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        // As in a conversation's preferences: an unknown voice name is kept; anything else is no voice.
        voice = (try? c.decodeIfPresent(String.self, forKey: .voice)).flatMap {
            RealtimeVoice.isPlausibleID($0) ? $0 : nil
        }
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
    public var isBuiltin: Bool { Self.reservedIDs.contains(id) }
    /// A stored character that a new one could not be: imported text over the limits. It cannot be picked until fixed.
    public var needsReview: Bool { (try? validateForWrite()) == nil }
    public static let userLimit = 200
    /// An unknown stored voice is not refused: it is kept, and the Settings voice speaks instead.
    public func validateForWrite() throws {
        try ConversationTemplate.validateName(name)
        try ConversationTemplate.validateText(
            description, field: "Description", characters: ConversationTemplate.descriptionLimit.characters,
            bytes: ConversationTemplate.descriptionLimit.bytes)
        try ConversationPersonality.validate(personality)
    }
    /// One edit to a character. nil keeps a field; a value replaces it after trimming and validation.
    public struct Patch: Equatable {
        public var name: String?
        public var description: String?
        public var personality: String?
        public var voice: ConversationSettingsPatch.Change<String>
        public init(
            name: String? = nil, description: String? = nil, personality: String? = nil,
            voice: ConversationSettingsPatch.Change<String> = .keep
        ) {
            self.name = name
            self.description = description
            self.personality = personality
            self.voice = voice
        }
        /// The changes that turn `current` into `target`, and nothing else.
        public init(changing current: ConversationCharacter, to target: ConversationCharacter) {
            self.init()
            if target.name != current.name { name = target.name }
            if target.description != current.description { description = target.description }
            if target.personality != current.personality { personality = target.personality }
            if target.voice != current.voice { voice = target.voice.map { .set($0) } ?? .clear }
        }
    }
    /// Only replaced fields are validated, so an imported character can be fixed one field at a time.
    public func applying(_ patch: Patch, creation: Bool = false) throws -> ConversationCharacter {
        var next = self
        if let value = patch.name {
            next.name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try ConversationTemplate.validateName(next.name)
        }
        if let value = patch.description {
            next.description = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try ConversationTemplate.validateText(
                next.description, field: "Description", characters: ConversationTemplate.descriptionLimit.characters,
                bytes: ConversationTemplate.descriptionLimit.bytes)
        }
        if let value = patch.personality {
            next.personality = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try ConversationPersonality.validate(next.personality)
        }
        switch patch.voice {
        case .keep: break
        case .clear: next.voice = nil
        case .set(let value):
            guard RealtimeVoice(rawValue: value) != nil else { throw AppFailure("Choose a supported OpenAI voice.") }
            next.voice = value
        }
        if creation {
            try next.validateForWrite()
        } else if next != self {
            if !needsReview { try next.validateForWrite() }
            next.revision = UUID().uuidString
            next.updatedAt = Date()
        }
        return next
    }
    /// The character as a tool result: text fields bounded, with the ones shortened named in `fields_truncated`.
    public func representation() -> [String: Any] {
        var truncated: [String: Bool] = [:]
        func bound(_ key: String, _ text: String, _ limit: ConversationTemplate.FieldLimit) -> String {
            let preview = text.bounded(characters: limit.characters, bytes: limit.bytes)
            if preview != text { truncated[key] = true }
            return preview
        }
        return [
            "id": id.uuidString, "name": bound("name", name, ConversationTemplate.nameLimit),
            "description": bound("description", description, ConversationTemplate.descriptionLimit),
            "personality": bound(
                "personality", personality, (ConversationPersonality.maxCharacters, ConversationPersonality.maxBytes)),
            "voice": voice as Any? ?? NSNull(), "origin": isBuiltin ? "built_in" : "user",
            "needs_review": needsReview, "fields_truncated": truncated,
        ]
    }

    // MARK: Built-in characters

    /// Built-in descriptions are stored in English, which their revision hashes; they are shown translated.
    public var displayDescription: String {
        Self.builtinNumbers[id].flatMap(Self.localizedDescription) ?? description
    }
    /// Each literal is a string-catalog key and must equal the stored English, which a test checks.
    private static func localizedDescription(_ number: Int) -> String? {
        switch number {
        case 1: String(localized: "Warm and thoughtful. Keeps replies short and leaves you room to think.")
        case 2: String(localized: "Curious and direct. Asks sharp follow-up questions.")
        case 3: String(localized: "Playful and imaginative. Loves wild ideas and wordplay.")
        default: nil
        }
    }
    private struct Definition {
        let name: String, description: String, personality: String
        let voice: RealtimeVoice?
    }
    /// Every built-in, in order: its place is its number, which fixes its ID. Append only.
    private static let definitions = [
        Definition(
            name: "Mochi", description: "Warm and thoughtful. Keeps replies short and leaves you room to think.",
            personality: "", voice: nil),
        Definition(
            name: "Alex", description: "Curious and direct. Asks sharp follow-up questions.",
            personality:
                "You are curious and direct. Ask sharp, specific follow-up questions, say plainly when something is unclear, and keep a brisk, friendly pace. Be encouraging, but never flatter.",
            voice: .cedar),
        Definition(
            name: "Pip", description: "Playful and imaginative. Loves wild ideas and wordplay.",
            personality:
                "You are playful and imaginative. Enjoy wordplay, unexpected angles and wild ideas, and bring lightness without making fun of anyone. When the user is serious, be gentle and calm.",
            voice: .coral),
    ]
    public static let builtins: [ConversationCharacter] = definitions.enumerated().map { index, entry in
        var c = ConversationCharacter(
            name: entry.name, description: entry.description, personality: entry.personality,
            voice: entry.voice?.rawValue)
        c.id = UUID(uuidString: String(format: "DAF3D004-0000-4000-8000-%012d", index + 1))!
        c.createdAt = Date(timeIntervalSince1970: 0)
        c.updatedAt = c.createdAt
        c.revision = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        c.revision = SHA256.hash(data: try! encoder.encode(c)).map { String(format: "%02x", $0) }.joined()
        return c
    }
    public static let reservedIDs: Set<UUID> = Set(builtins.map(\.id))
    private static let builtinNumbers = Dictionary(
        uniqueKeysWithValues: builtins.enumerated().map { ($1.id, $0 + 1) })
}
