import Foundation
import MochiAutomation
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
    public init(_ arguments: ConversationSettingsArguments) {
        instructions = arguments.instructions
        characterName = arguments.clearCharacterName == true ? .clear : arguments.characterName.map(Change.set) ?? .keep
        speed = arguments.clearSpeed == true ? .clear : arguments.speed.map(Change.set) ?? .keep
        coaching = arguments.coaching
    }
    public var isEmpty: Bool { self == ConversationSettingsPatch() }
    /// Applies every change or none: on failure `settings` is left untouched.
    public func apply<Settings: ConversationSettingsHolder>(to settings: inout Settings) throws {
        var next = settings
        if let instructions {
            try MochiTools.validateInstructions(instructions)
            next.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch characterName {
        case .keep: break
        case .clear: next.characterName = nil
        case .set(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            try ConversationTemplate.validateName(trimmed)
            next.characterName = trimmed
        }
        switch speed {
        case .keep: break
        case .clear: next.preferences.speed = nil
        case .set(let value): next.preferences.speed = value
        }
        if let coaching { next.preferences.coaching = coaching }
        try next.preferences.validate()
        settings = next
    }
}
