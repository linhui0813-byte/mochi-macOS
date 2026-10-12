import CryptoKit
import Foundation

public enum ReferenceSpeech {
    /// Generated speech did not read the requested text exactly, or was cut off; retrying may succeed.
    public struct Mismatch: Error { public init() {} }
    public static let preview = "I would like a little more time to think. Then I can explain what I mean."
    public static func matches(_ expected: String, _ actual: String) -> Bool {
        func words(_ text: String) -> String {
            // Canonical composition plus kept marks: "café" and "cafe\u{0301}" are the same word.
            text.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "[^\\p{L}\\p{M}\\p{N}']+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalized = words(expected)
        return !normalized.isEmpty && normalized == words(actual)
    }
    public static func cacheName(
        text: String, model: String, voice: String, options: OpenAIVoiceOptions = OpenAIVoiceOptions()
    ) -> String {
        // JSON has no non-finite numbers; spelling them out keeps the serialization below infallible.
        let speed: Any = options.speed.isFinite ? options.speed : String(options.speed)
        let data = try! JSONSerialization.data(
            withJSONObject: ["text": text, "model": model, "voice": voice, "version": "2", "speed": speed],
            options: .sortedKeys)
        return "builtin-\(SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()).wav"
    }
}
