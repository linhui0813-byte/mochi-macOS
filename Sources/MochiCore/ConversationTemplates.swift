import CryptoKit
import Foundation
import MochiAutomation
import MochiKernel

public struct ConversationTemplate: Codable, Identifiable, Equatable {
    public var id: UUID
    public var revision: String
    public var title: String
    public var description: String
    public var characterName: String?
    public var instructions: String
    public var preferences: ConversationPreferences
    public var createdAt: Date
    public var updatedAt: Date
    public init(
        title: String, description: String = "", characterName: String? = nil, instructions: String = "",
        preferences: ConversationPreferences = ConversationPreferences()
    ) {
        id = UUID()
        revision = UUID().uuidString
        self.title = title
        self.description = description
        self.characterName = characterName
        self.instructions = instructions
        self.preferences = preferences
        createdAt = Date()
        updatedAt = createdAt
    }
    public var isBuiltin: Bool { Self.reservedIDs.contains(id) }
    public var needsReview: Bool { (try? validateForWrite()) == nil }
    public static let userLimit = 200
    public typealias FieldLimit = (characters: Int, bytes: Int)
    public static let titleLimit: FieldLimit = (160, 2048)
    public static let descriptionLimit: FieldLimit = (500, 4096)
    public static let nameLimit: FieldLimit = (80, 1024)
    public static let instructionsLimit: FieldLimit = (MochiTools.maxInstructions, MochiTools.maxInstructionBytes)
    public static let reservedIDs: Set<UUID> = Set(builtins.map(\.id))
    private static func builtinID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "DAF3D003-0000-4000-8000-%012d", number))!
    }
    public static func validateName(_ name: String?) throws {
        guard let name else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= nameLimit.characters,
            name.utf8.count <= nameLimit.bytes, !name.unicodeScalars.contains(where: Self.forbiddenInName)
        else {
            throw AppFailure(
                "Character name must contain 1–\(nameLimit.characters) characters, at most \(nameLimit.bytes / 1024) KB, without line breaks, control characters or text-direction overrides."
            )
        }
    }
    /// Control characters, line breaks and bidirectional overrides are refused. Joiners and the emoji variation
    /// selector are format characters that real names need (emoji sequences, Persian spelling), so they are allowed.
    static func forbiddenInName(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.newlines.contains(scalar) { return true }
        if scalar.properties.generalCategory == .control { return true }
        return (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }
    public static func validateText(
        _ value: String, field: String.LocalizationValue, characters: Int, bytes: Int, required: Bool = false
    )
        throws
    {
        guard value.count <= characters, value.utf8.count <= bytes,
            !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            let name = String(localized: field)
            throw required
                ? AppFailure(
                    "\(name) must contain text and fit within \(characters) characters and \(bytes / 1024) KB.")
                : AppFailure("\(name) must fit within \(characters) characters and \(bytes / 1024) KB.")
        }
    }
    public func validateForWrite() throws {
        try Self.validateText(
            title, field: "Template title", characters: Self.titleLimit.characters, bytes: Self.titleLimit.bytes,
            required: true)
        try Self.validateText(
            description, field: "Description", characters: Self.descriptionLimit.characters,
            bytes: Self.descriptionLimit.bytes)
        try Self.validateName(characterName)
        try MochiTools.validateInstructions(instructions)
        try preferences.validate()
        try validateMeaningful()
        guard try JSONSerialization.data(withJSONObject: fullRepresentation).count < 100000 else {
            throw AppFailure("Encoded template is too large. Shorten its text.")
        }
    }
    private func validateMeaningful() throws {
        guard
            !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || characterName != nil
                || preferences.coaching != .natural || preferences.speed != nil
        else {
            throw AppFailure("Add instructions, a character name, coaching, or speech speed to this template.")
        }
    }
    /// Shared UI/MCP normalization. Only replaced fields are validated; recovery data is retained.
    public func applying(_ fields: [String: Any], creation: Bool = false) throws -> ConversationTemplate {
        let args =
            creation
            ? fields
            : fields.merging(["template_id": id.uuidString, "expected_template_revision": revision]) { _, trusted in
                trusted
            }
        _ = try MochiTools.validate(
            name: creation
                ? MochiToolName.createConversationTemplate.rawValue : MochiToolName.updateConversationTemplate.rawValue,
            arguments: args, origin: .external)
        let metadata = try MochiTools.decode(TemplateArguments.self, from: args)
        var next = self
        if let value = metadata.title {
            next.title = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validateText(
                next.title, field: "Template title", characters: Self.titleLimit.characters,
                bytes: Self.titleLimit.bytes, required: true)
        }
        if let value = metadata.description {
            next.description = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validateText(
                next.description, field: "Description", characters: Self.descriptionLimit.characters,
                bytes: Self.descriptionLimit.bytes)
        }
        try ConversationSettingsPatch(MochiTools.decode(ConversationSettingsArguments.self, from: args)).apply(
            to: &next)
        try next.validateMeaningful()
        if creation {
            try next.validateForWrite()
        } else if next != self {
            if !needsReview { try next.validateForWrite() }
            next.revision = UUID().uuidString
            next.updatedAt = Date()
        }
        return next
    }
    /// Recovery feedback: counts only templates this import added, and reports the soft cap without blocking recovery.
    public static func importSummary(
        conversations: Int, imported: [ConversationTemplate], merged: [ConversationTemplate], localIDs: Set<UUID>
    ) -> String {
        let added = merged.filter { !localIDs.contains($0.id) }
        var text =
            "Imported \(conversations) conversations and \(added.count) templates. Existing local items were kept. \(imported.count - added.count) duplicate templates skipped. \(added.filter(\.needsReview).count) imported templates need review."
        if merged.count > userLimit {
            text +=
                " You have \(merged.count) user templates, above the \(userLimit) limit; all remain usable, but remove some before creating more."
        }
        return text
    }
    public func conversation(title: String? = nil) throws -> Conversation {
        // Only settings copied into the conversation are relevant here; catalog metadata stays intact.
        try MochiTools.validateInstructions(instructions)
        try Self.validateName(characterName)
        try preferences.validate()
        var chat = Conversation()
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chat.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            chat.customTitle = true
        }
        chat.instructions = instructions
        chat.characterName = characterName
        chat.preferences = preferences
        chat.sourceTemplateID = id
        chat.sourceTemplateRevision = revision
        return chat
    }
    private var fullRepresentation: [String: Any] {
        [
            "id": id.uuidString, "template_revision": revision, "title": title, "description": description,
            "character_name": characterName as Any? ?? NSNull(), "instructions": instructions,
            "coaching": preferences.coaching.rawValue,
            "speed": preferences.speed as Any? ?? NSNull(), "origin": isBuiltin ? "built_in" : "user",
            "created_at": createdAt.formatted(.iso8601), "updated_at": updatedAt.formatted(.iso8601),
        ]
    }
    public func representation(includeInstructions: Bool = true) -> [String: Any] {
        var value = fullRepresentation
        var truncated: [String: Bool] = [:]
        func bound(_ key: String, _ limit: FieldLimit) {
            guard let original = value[key] as? String else { return }
            let preview = MochiTools.boundedText(original, characters: limit.characters, bytes: limit.bytes)
            value[key] = preview
            if preview != original { truncated[key] = true }
        }
        bound("title", Self.titleLimit)
        bound("description", Self.descriptionLimit)
        bound("character_name", Self.nameLimit)
        if includeInstructions {
            bound("instructions", Self.instructionsLimit)
            var byteLimit = Self.instructionsLimit.bytes
            while ((try? JSONSerialization.data(withJSONObject: value).count) ?? Int.max) > 95000 && byteLimit > 0 {
                byteLimit /= 2
                bound("instructions", (Self.instructionsLimit.characters, byteLimit))
            }
        } else {
            value.removeValue(forKey: "instructions")
        }
        value["fields_truncated"] = truncated
        value["needs_review"] = needsReview
        return value
    }
    /// Built-in templates are stored in English, since their revision hashes that text; they are shown translated.
    public var displayTitle: String {
        guard isBuiltin else { return title }
        switch title {
        case "Restaurant": return String(localized: "Restaurant")
        case "Hotel check-in": return String(localized: "Hotel check-in")
        case "Job interview": return String(localized: "Job interview")
        case "Vocabulary recall": return String(localized: "Vocabulary recall")
        case "Pronunciation and shadowing": return String(localized: "Pronunciation and shadowing")
        case "Topic discussion": return String(localized: "Topic discussion")
        default: return title
        }
    }
    public var displayDescription: String {
        guard isBuiltin else { return description }
        switch description {
        case "Order a meal and handle follow-up questions.":
            return String(localized: "Order a meal and handle follow-up questions.")
        case "Practise arrivals, reservations, and requests.":
            return String(localized: "Practise arrivals, reservations, and requests.")
        case "Practise explaining experience and answering questions.":
            return String(localized: "Practise explaining experience and answering questions.")
        case "Recall words and use them in your own sentences.":
            return String(localized: "Recall words and use them in your own sentences.")
        case "Listen, record, and compare selected sentences.":
            return String(localized: "Listen, record, and compare selected sentences.")
        case "Discuss something interesting at your own pace.":
            return String(localized: "Discuss something interesting at your own pace.")
        default: return description
        }
    }
    public static let builtins: [ConversationTemplate] = {
        let entries: [(String, String, String, String)] = [
            (
                "Restaurant", "Order a meal and handle follow-up questions.", "Alex",
                "You are Alex, a restaurant server. The user is a customer. Help them practise ordering a meal and asking about ingredients. Ask one natural question at a time. Stay in role; ask for missing preferences instead of inventing them."
            ),
            (
                "Hotel check-in", "Practise arrivals, reservations, and requests.", "Alex",
                "You are Alex at a hotel reception desk. The user is a guest checking in. Practise a realistic check-in and special requests. Ask one question at a time. Ask for reservation details instead of inventing them."
            ),
            (
                "Job interview", "Practise explaining experience and answering questions.", "Alex",
                "You are Alex, an interviewer. Ask the user what job they are preparing for, then conduct a realistic interview one question at a time. Ask follow-ups about their own answers; do not invent their experience."
            ),
            (
                "Vocabulary recall", "Recall words and use them in your own sentences.", "Mochi",
                "Ask for a word list, then practise active recall, meanings, and original examples one word at a time. Give hints only after the learner attempts an answer or asks. Revisit missed words in this conversation. Do not claim long-term mastery or scheduled spaced repetition."
            ),
            (
                "Pronunciation and shadowing", "Listen, record, and compare selected sentences.", "Mochi",
                "Ask for a word or sentence to practise. Help prepare it for reference playback and shadowing with Mochi's existing practice tools. Recording is always initiated by the user. Discuss listening and comparison; never give a pronunciation score from pitch similarity or uncertain transcription, and do not pretend to have assessed audio you have not received."
            ),
            (
                "Topic discussion", "Discuss something interesting at your own pace.", "Mochi",
                "Ask what topic the user would like to discuss. Explore their ideas with natural follow-up questions, one at a time. Respond to the substance of their answers and give them room to think."
            ),
        ]
        return entries.enumerated().map { index, entry in
            var t = ConversationTemplate(
                title: entry.0, description: entry.1, characterName: entry.2, instructions: entry.3)
            t.id = builtinID(index + 1)
            t.createdAt = Date(timeIntervalSince1970: 0)
            t.updatedAt = t.createdAt
            t.revision = ""
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            t.revision = SHA256.hash(data: try! encoder.encode(t)).map { String(format: "%02x", $0) }.joined()
            return t
        }
    }()
}
