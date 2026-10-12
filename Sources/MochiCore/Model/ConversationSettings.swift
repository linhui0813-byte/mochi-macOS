import Foundation
import MochiKernel

/// The settings a conversation copies from a template and can change later.
public protocol ConversationSettingsHolder {
    var instructions: String { get set }
    var characterName: String? { get set }
    var personality: String { get set }
    var greeting: String { get set }
    var phrases: [String] { get set }
    var preferences: ConversationPreferences { get set }
}
extension Conversation: ConversationSettingsHolder {}
extension ConversationTemplate: ConversationSettingsHolder {}
extension ConversationSettingsHolder {
    /// Takes every setting from `other`. The one list of them, so no copy between setups can leave one behind.
    public mutating func adoptSettings(from other: some ConversationSettingsHolder) {
        instructions = other.instructions
        characterName = other.characterName
        personality = other.personality
        greeting = other.greeting
        phrases = other.phrases
        preferences = other.preferences
    }
    /// Takes a character's name, personality and voice, and nothing else; nothing records which character it was.
    public mutating func adoptCharacter(_ character: ConversationCharacter) {
        characterName = character.name
        personality = character.personality
        preferences.voice = character.voice
    }
    /// Whether the companion here is exactly `character`.
    public func hasCharacter(_ character: ConversationCharacter) -> Bool {
        characterName == character.name && personality == character.personality
            && preferences.voice == character.voice
    }
}

/// One change to conversation settings, validated and normalised the same way for the UI, MCP and templates.
public struct ConversationSettingsPatch: Equatable {
    public enum Change<Value: Equatable>: Equatable {
        case keep
        case set(Value)
        case clear
    }
    /// nil keeps the current instructions; a value replaces them after validation and trimming.
    public var instructions: String?
    public var characterName: Change<String> = .keep
    public var speed: Change<Double> = .keep
    public var coaching: CoachingStyle?
    public var language: ConversationLanguage?
    /// nil keeps the current text; a value replaces it after trimming, and an empty one clears it.
    public var personality: String?
    public var greeting: String?
    /// nil keeps the current phrases; a list replaces them, trimmed and without empty ones.
    public var phrases: [String]?
    /// Setting a voice requires one this version supports; keeping one leaves even an unknown stored voice alone.
    public var voice: Change<String> = .keep
    public init(
        instructions: String? = nil, characterName: Change<String> = .keep, speed: Change<Double> = .keep,
        coaching: CoachingStyle? = nil, language: ConversationLanguage? = nil, personality: String? = nil,
        greeting: String? = nil, phrases: [String]? = nil, voice: Change<String> = .keep
    ) {
        self.instructions = instructions
        self.characterName = characterName
        self.speed = speed
        self.coaching = coaching
        self.language = language
        self.personality = personality
        self.greeting = greeting
        self.phrases = phrases
        self.voice = voice
    }
    /// The changes that turn `current` into `target`, and nothing else, so a stored value the editor showed but the
    /// user left alone is never validated or rewritten.
    public init(changing current: some ConversationSettingsHolder, to target: some ConversationSettingsHolder) {
        self.init()
        if target.instructions != current.instructions { instructions = target.instructions }
        if target.characterName != current.characterName {
            characterName = target.characterName.map { .set($0) } ?? .clear
        }
        if target.personality != current.personality { personality = target.personality }
        if target.greeting != current.greeting { greeting = target.greeting }
        if target.phrases != current.phrases { phrases = target.phrases }
        let (now, next) = (current.preferences, target.preferences)
        if next.speed != now.speed { speed = next.speed.map { .set($0) } ?? .clear }
        if next.coaching != now.coaching { coaching = next.coaching }
        if next.language != now.language { language = next.language }
        if next.voice != now.voice { voice = next.voice.map { .set($0) } ?? .clear }
    }
    public var isEmpty: Bool { self == ConversationSettingsPatch() }
    /// Applies every change or none: everything is validated before `settings` is touched, even for class conformers.
    public func apply<Settings: ConversationSettingsHolder>(to settings: inout Settings) throws {
        if let instructions { try ConversationInstructions.validate(instructions) }
        let name: String??
        switch characterName {
        case .keep: name = nil
        case .clear: name = .some(nil)
        case .set(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try ConversationTemplate.validateName(trimmed)
            name = trimmed
        }
        let personality = self.personality?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let personality { try ConversationPersonality.validate(personality) }
        let greeting = self.greeting?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let greeting { try ConversationGreeting.validate(greeting) }
        let phrases = self.phrases.map(ConversationPhrases.normalized)
        if let phrases { try ConversationPhrases.validate(phrases) }
        var preferences = settings.preferences
        switch speed {
        case .keep: break
        case .clear: preferences.speed = nil
        case .set(let value): preferences.speed = value
        }
        if let coaching { preferences.coaching = coaching }
        if let language { preferences.language = language }
        switch voice {
        case .keep: break
        case .clear: preferences.voice = nil
        case .set(let value):
            guard RealtimeVoice(rawValue: value) != nil else { throw AppFailure("Choose a supported OpenAI voice.") }
            preferences.voice = value
        }
        try preferences.validate()
        if let instructions { settings.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let name { settings.characterName = name }
        if let personality { settings.personality = personality }
        if let greeting { settings.greeting = greeting }
        if let phrases { settings.phrases = phrases }
        settings.preferences = preferences
    }
}
