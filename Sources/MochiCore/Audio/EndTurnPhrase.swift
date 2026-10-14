import Foundation

/// A distinctive English control phrase, matched as whole words at the end of local recognition.
public struct EndTurnPhrase: Equatable {
    public static let defaultValue = "over over"
    public let text: String
    public let words: [String]
    public init?(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Self.words(in: text)
        guard !text.isEmpty, text.count <= 64, (1...8).contains(words.count),
            text.unicodeScalars.allSatisfy({ scalar in
                scalar.value < 128 && (CharacterSet.letters.contains(scalar) || " '-".unicodeScalars.contains(scalar))
            })
        else { return nil }
        self.text = text
        self.words = words
    }
    public static func words(in text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    public func matchesEnding(in text: String) -> Bool {
        Array(Self.words(in: text).suffix(words.count)) == words
    }
}

/// Matches partial and finalized blocks without letting a late result finish a newer voice turn.
public struct EndPhraseRecognitionWindow {
    private let phrase: EndTurnPhrase
    private var minimumEndTime: Double?
    private var finalizedTail: [String] = []
    public init(phrase: EndTurnPhrase) { self.phrase = phrase }
    public mutating func begin(at time: Double) {
        minimumEndTime = max(0, time)
        finalizedTail = []
    }
    public mutating func end() {
        minimumEndTime = nil
        finalizedTail = []
    }
    public mutating func accept(text: String, isFinal: Bool, endingAt time: Double) -> Bool {
        guard let minimumEndTime, time.isFinite, time >= minimumEndTime else { return false }
        let words = finalizedTail + EndTurnPhrase.words(in: text)
        if Array(words.suffix(phrase.words.count)) == phrase.words {
            end()
            return true
        }
        if isFinal { finalizedTail = Array(words.suffix(max(0, phrase.words.count - 1))) }
        return false
    }
}
