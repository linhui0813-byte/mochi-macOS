import SwiftUI

/// Each character's colour in the conversation list. It comes from the character's name, so a character keeps its
/// colour across launches and every conversation with it shares one. Swift's `hashValue` changes on every launch, so
/// the name is hashed with FNV-1a, which does not.
enum CharacterColor {
    /// System colours that read in light and dark mode. Yellow is left out: it is hard to see on white.
    static let palette: [Color] = [.blue, .purple, .pink, .red, .orange, .green, .mint, .teal, .cyan, .indigo, .brown]

    static func index(for name: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(palette.count))
    }

    static func color(for name: String) -> Color { palette[index(for: name)] }
}
