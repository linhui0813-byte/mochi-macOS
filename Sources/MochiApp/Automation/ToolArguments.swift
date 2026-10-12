import MochiAutomation
import MochiCore

/// Tool arguments become the same typed edits the interface makes, so one domain path validates both.
/// The schema checks stay at the tool boundary: `MochiTools.validate` runs before any of these.
extension ConversationSettingsPatch {
    init(_ arguments: ConversationSettingsArguments) {
        self.init(
            instructions: arguments.instructions,
            characterName: arguments.clearCharacterName == true
                ? .clear : arguments.characterName.map(Change.set) ?? .keep,
            speed: arguments.clearSpeed == true ? .clear : arguments.speed.map(Change.set) ?? .keep,
            coaching: arguments.coaching, language: arguments.language, personality: arguments.personality,
            greeting: arguments.greeting, phrases: arguments.phrases,
            voice: arguments.clearVoice == true ? .clear : arguments.voice.map(Change.set) ?? .keep)
    }
    init(toolArguments arguments: [String: Any]) throws {
        self.init(try MochiTools.decode(ConversationSettingsArguments.self, from: arguments))
    }
}
extension ConversationTemplate.Patch {
    init(toolArguments arguments: [String: Any]) throws {
        let metadata = try MochiTools.decode(TemplateArguments.self, from: arguments)
        self.init(
            title: metadata.title, description: metadata.description,
            settings: try ConversationSettingsPatch(toolArguments: arguments))
    }
}
