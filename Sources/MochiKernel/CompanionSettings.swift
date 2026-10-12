import Foundation

/// Text that must stay on one line: line breaks, control characters and text-direction overrides are refused.
/// Joiners and the emoji variation selector are format characters real text needs, so they are allowed.
public enum SingleLineText {
    public static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.newlines.contains(scalar) { return true }
        if scalar.properties.generalCategory == .control { return true }
        return (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }
    public static func isValid(_ text: String) -> Bool { !text.unicodeScalars.contains(where: isForbidden) }
}

/// How the companion comes across: its manner and temperament, kept apart from what the conversation is for.
public enum ConversationPersonality {
    public static let maxCharacters = 2000
    public static let maxBytes = 12288
    public static func validate(_ value: String) throws {
        guard value.count <= maxCharacters, value.utf8.count <= maxBytes else {
            throw AppFailure("A personality cannot exceed 2,000 characters or 12 KB.")
        }
    }
    /// The longest prefix within the limits, for text imported from elsewhere.
    public static func bounded(_ text: String) -> String { text.bounded(characters: maxCharacters, bytes: maxBytes) }
}

/// The first thing the companion says when the user starts talking, spoken exactly as written.
public enum ConversationGreeting {
    public static let maxCharacters = 160
    public static let maxBytes = 1024
    public static func validate(_ value: String) throws {
        guard value.count <= maxCharacters, value.utf8.count <= maxBytes, SingleLineText.isValid(value) else {
            throw AppFailure("A greeting must be one line of at most 160 characters.")
        }
    }
}

/// Lines the user can send with one click. Each is ordinary text, sent exactly as shown.
public enum ConversationPhrases {
    public static let maxCount = 6
    public static let maxCharacters = 100
    public static let maxBytes = 1024
    public static func validate(_ phrases: [String]) throws {
        guard phrases.count <= maxCount else { throw AppFailure("Use at most 6 phrases.") }
        for phrase in phrases {
            guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, phrase.count <= maxCharacters,
                phrase.utf8.count <= maxBytes, SingleLineText.isValid(phrase)
            else { throw AppFailure("Each phrase must be one line of 1 to 100 characters.") }
        }
    }
    /// Each phrase without surrounding spaces, and no empty ones: how the editors and the tools store them.
    public static func normalized(_ phrases: [String]) -> [String] {
        phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
