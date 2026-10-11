import Foundation

/// The limits on a conversation's custom instructions, shared by the library, the voice service and the tools.
public enum ConversationInstructions {
    public static let maxCharacters = 8000
    public static let maxBytes = 49152
    public static func validate(_ value: String) throws {
        guard value.count <= maxCharacters, value.utf8.count <= maxBytes else {
            throw AppFailure("Conversation instructions cannot exceed 8,000 characters or 48 KB.")
        }
    }
    /// The longest prefix within the limits, for text kept from before the limits existed.
    public static func bounded(_ text: String) -> String {
        text.bounded(characters: maxCharacters, bytes: maxBytes)
    }
}
extension String {
    /// The longest prefix of whole characters within both a character and a UTF-8 byte limit.
    public func bounded(characters: Int, bytes: Int) -> String {
        var result = ""
        var used = 0
        for character in prefix(characters) {
            let size = String(character).utf8.count
            guard used + size <= bytes else { break }
            result.append(character)
            used += size
        }
        return result
    }
}
