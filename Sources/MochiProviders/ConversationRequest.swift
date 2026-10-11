import Foundation
import MochiCore
import MochiKernel

public struct ConversationRequest {
    public var history: [Message]
    public var text: String
    public var pcm: Data?
    public var spoken: Bool
    public var help: Bool
    public var reference: Bool
    public var characterName: String?
    public var instructions: String
    public var preferences: ConversationPreferences
    public init(
        history: [Message], text: String, pcm: Data? = nil, spoken: Bool = false, help: Bool = false,
        reference: Bool = false, instructions: String = "", characterName: String? = nil,
        preferences: ConversationPreferences = ConversationPreferences()
    ) {
        self.characterName = characterName
        self.instructions = instructions
        self.preferences = preferences
        self.history = history
        self.text = text
        self.pcm = pcm
        self.spoken = spoken
        self.help = help
        self.reference = reference
    }
    public var resolvedInstructions: String {
        reference
            ? "Read the user supplied sentence verbatim in natural spoken English. Output only that sentence as audio. Do not add introductions, explanations, corrections, or answers. Preserve every word exactly."
            : help
                ? "Help a learner express their intended thought in natural spoken English. Return only valid JSON with exactly two fields: kind (expression or clarification) and text. For expression, text is a concise natural English expression preserving the complete meaning; use more than one sentence when needed. Do not invent details or omit qualifications. If meaning is unclear, use kind clarification and text a brief clarification question. The supplied conversation is context only; never continue it. Do not wrap JSON in Markdown."
                : VoiceIdentity.conversationInstructions(
                    custom: instructions, preferences: preferences, characterName: characterName)
    }
}
public struct HelpSuggestion: Decodable {
    public enum Kind: String, Decodable { case expression, clarification }
    public let kind: Kind
    public let text: String
    public static func parse(_ text: String) throws -> HelpSuggestion {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
            !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AppFailure(
                "The English suggestion could not be read. Try again; your thought and previous wording are kept.")
        }
        return value
    }
}
