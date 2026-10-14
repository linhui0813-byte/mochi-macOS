import XCTest

@testable import MochiCore

final class SpeechTurnDetectorTests: XCTestCase {
    private func voiced(_ frames: Int) -> Data { Data(Array(repeating: [UInt8(0), 32], count: 480 * frames).joined()) }
    private func quiet(_ frames: Int) -> Data { Data(repeating: 0, count: frames * 960) }
    func testSilenceAndShortClicksNeverStartATurn() {
        var detector = SpeechTurnDetector()
        XCTAssertEqual(detector.accept(quiet(200)), [])
        XCTAssertEqual(detector.accept(voiced(3)), [])
        XCTAssertEqual(detector.accept(quiet(100)), [])
        XCTAssertFalse(detector.speaking)
    }
    func testStartsBeforeTheUtteranceEndsAndAllowsOrdinaryPauses() {
        var detector = SpeechTurnDetector()
        _ = detector.accept(quiet(400))
        XCTAssertEqual(detector.accept(voiced(12)), [.started])
        XCTAssertEqual(detector.accept(quiet(35)), [], "A short thinking pause must not submit the turn")
        XCTAssertEqual(detector.accept(voiced(12)), [])
        let events = detector.accept(quiet(55))
        XCTAssertEqual(events.count, 1)
        guard case .ended(let data) = events.first else { return XCTFail("Expected one automatic speech turn") }
        XCTAssertLessThan(data.count, 48000 * 3, "Do not upload the long wait before speech")
        XCTAssertFalse(detector.speaking)
    }
    func testArbitraryChunkBoundariesAndConsecutiveTurns() {
        let one = voiced(20) + quiet(60)
        let input = one + one
        var whole = SpeechTurnDetector()
        var split = SpeechTurnDetector()
        let expected = whole.accept(input)
        var actual: [SpeechTurnDetector.Event] = []
        for offset in stride(from: 0, to: input.count, by: 773) {
            actual += split.accept(input.subdata(in: offset..<min(offset + 773, input.count)))
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 4)
    }
    func testLongSpeechIsBoundedAtSixtySeconds() {
        var detector = SpeechTurnDetector()
        let events = detector.accept(voiced(3010))
        guard
            let ended = events.first(where: {
                if case .ended = $0 { return true }
                return false
            }),
            case .ended(let data) = ended
        else { return XCTFail("Long speech must be bounded") }
        XCTAssertLessThanOrEqual(data.count, 2_880_000)
    }
    func testInterruptedEndingIsExcludedFromContextAndSurvivesSaving() throws {
        var message = Message(role: "assistant", text: "Heard beginning. Unheard ending.")
        message.interrupted = true
        let copy = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
        XCTAssertTrue(copy.interrupted)
        XCTAssertFalse(copy.contextText?.contains("Unheard ending") == true)
        XCTAssertEqual(copy.displayText, message.text)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object["interrupted"] = nil
        let legacy = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(legacy.interrupted)
    }
}
