import Foundation

/// The voices Mochi can speak in. Conversations, templates, characters and the tools all validate against this list.
public enum RealtimeVoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case marin, cedar, alloy, ash, ballad, coral, echo, sage, shimmer, verse
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
    /// Whether `value` could name a voice: 1–64 letters, digits, dots, hyphens or underscores. A stored voice this
    /// version does not know is kept when it passes, so a library from a Mochi with more voices keeps its choice.
    public static func isPlausibleID(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                    || "._-".unicodeScalars.contains($0)
            }
    }
}
