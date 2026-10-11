import Foundation
import MochiKernel

/// The settings a conversation copies from a template and can change later.
public protocol ConversationSettingsHolder {
    var instructions: String { get set }
    var characterName: String? { get set }
    var preferences: ConversationPreferences { get set }
}
extension Conversation: ConversationSettingsHolder {}
extension ConversationTemplate: ConversationSettingsHolder {}

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
    public init(
        instructions: String? = nil, characterName: Change<String> = .keep, speed: Change<Double> = .keep,
        coaching: CoachingStyle? = nil
    ) {
        self.instructions = instructions
        self.characterName = characterName
        self.speed = speed
        self.coaching = coaching
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
        var preferences = settings.preferences
        switch speed {
        case .keep: break
        case .clear: preferences.speed = nil
        case .set(let value): preferences.speed = value
        }
        if let coaching { preferences.coaching = coaching }
        try preferences.validate()
        if let instructions { settings.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let name { settings.characterName = name }
        settings.preferences = preferences
    }
}
