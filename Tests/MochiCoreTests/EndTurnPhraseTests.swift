import XCTest

@testable import MochiCore

final class EndTurnPhraseTests: XCTestCase {
    func testDefaultWholeWordMatchIgnoresCaseAndRecognitionPunctuation() throws {
        let phrase = try XCTUnwrap(EndTurnPhrase(EndTurnPhrase.defaultValue))
        XCTAssertTrue(phrase.matchesEnding(in: "My thought. Over, over!"))
        for text in ["over", "moreover over", "over overpasses", "over over and another thought"] {
            XCTAssertFalse(phrase.matchesEnding(in: text))
        }
    }
    func testPhraseValidationAndCustomPhrase() throws {
        let custom = try XCTUnwrap(EndTurnPhrase(" finished now "))
        XCTAssertTrue(custom.matchesEnding(in: "A sentence, FINISHED NOW."))
        XCTAssertFalse(custom.matchesEnding(in: "A sentence over over"))
        for phrase in [
            "", "   ", "two\nlines", "结束结束", String(repeating: "a", count: 65),
            "one two three four five six seven eight nine",
        ] {
            XCTAssertNil(EndTurnPhrase(phrase))
        }
    }
    func testSplitRecognitionBlocksFireOnceAndLateResultsCannotFinishANewerTurn() throws {
        var window = EndPhraseRecognitionWindow(phrase: try XCTUnwrap(EndTurnPhrase("over over")))
        window.begin(at: 10)
        XCTAssertFalse(window.accept(text: "old over over", isFinal: true, endingAt: 9))
        XCTAssertFalse(window.accept(text: "A sentence over", isFinal: true, endingAt: 12))
        XCTAssertTrue(window.accept(text: "over", isFinal: false, endingAt: 12.4))
        XCTAssertFalse(window.accept(text: "over", isFinal: true, endingAt: 12.4))
        window.begin(at: 20)
        XCTAssertFalse(window.accept(text: "over over", isFinal: true, endingAt: 12.4))
        XCTAssertFalse(window.accept(text: "new speech", isFinal: false, endingAt: 21))
        window.end()
        XCTAssertFalse(window.accept(text: "over over", isFinal: false, endingAt: 22))
    }
}
