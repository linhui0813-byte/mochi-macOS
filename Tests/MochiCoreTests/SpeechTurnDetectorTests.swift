import MochiTestSupport
import XCTest

@testable import MochiCore

final class SpeechTurnDetectorTests: XCTestCase {
    func testExplicitFinishSubmitsSpeechWithoutQuietAndResetsForTheNextTurn() throws {
        let detector = SpeechTurnDetector()
        XCTAssertNil(detector.finishSpeech(), "An idle microphone must not submit an empty recording")
        XCTAssertEqual(detector.accept(SpeechFixture.voiced(frames: 100)), [.started])
        let audio = try XCTUnwrap(detector.finishSpeech())
        XCTAssertGreaterThan(audio.count, 4800)
        XCTAssertFalse(detector.speaking)
        XCTAssertNil(detector.finishSpeech(), "Repeated phrase results must not resubmit a turn")
        XCTAssertEqual(detector.accept(Data(repeating: 0, count: 960 * 90)), [])
        XCTAssertEqual(detector.accept(SpeechFixture.voiced(frames: 45)), [.started])
    }
    private func voiced(_ frames: Int) -> Data { SpeechFixture.voiced(frames: frames) }
    private func quiet(_ frames: Int) -> Data { Data(repeating: 0, count: frames * 960) }
    private func scaled(_ data: Data, gain: Double) -> Data {
        var result = Data()
        for index in stride(from: 0, to: data.count, by: 2) {
            let sample = Int16(bitPattern: UInt16(data[index]) | UInt16(data[index + 1]) << 8)
            var value = Int16((Double(sample) * gain).rounded()).littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        return result
    }
    private func noise(_ frames: Int) -> Data {
        var state: UInt32 = 12345
        var result = Data()
        for _ in 0..<frames * 480 {
            state = state &* 1_664_525 &+ 1_013_904_223
            var sample = Int16(Int(state >> 16) % 1001 - 500).littleEndian
            withUnsafeBytes(of: &sample) { result.append(contentsOf: $0) }
        }
        return result
    }
    func testQuietSpeechBelowTheOldLoudnessCutoffStillSubmitsAfterAPause() {
        let detector = SpeechTurnDetector()
        _ = detector.accept(quiet(50))
        let events = detector.accept(scaled(SpeechFixture.pcm, gain: 0.025) + quiet(90))
        XCTAssertTrue(events.contains(.started), "Real speech must not depend on a fixed microphone gain")
        XCTAssertTrue(
            events.contains {
                if case .ended = $0 { return true }
                return false
            })
    }
    func testPlaybackOnsetFloorRejectsFaintSpeechButKeepsASofterSentenceEnding() {
        let detector = SpeechTurnDetector()
        XCTAssertEqual(detector.accept(scaled(voiced(45), gain: 0.01) + quiet(90), minimumSpeechLevelDB: -40), [])
        XCTAssertEqual(detector.accept(voiced(30), minimumSpeechLevelDB: -40), [.started])
        XCTAssertEqual(
            detector.accept(scaled(voiced(45), gain: 0.025), minimumSpeechLevelDB: -40), [],
            "A softer ending must stay in the same utterance after a valid onset")
        let events = detector.accept(quiet(90), minimumSpeechLevelDB: -40)
        XCTAssertEqual(events.count, 1)
        XCTAssertNotNil(detector.lastSpeechPeakDB)
    }
    func testBackgroundNoiseDoesNotPreventSpeechFromEnding() {
        let detector = SpeechTurnDetector()
        XCTAssertEqual(detector.accept(noise(200)), [], "Steady background noise must not create a turn")
        let voice = SpeechFixture.pcm
        let background = noise(voice.count / 960 + 1)
        var mixed = Data()
        for index in stride(from: 0, to: voice.count, by: 2) {
            let a = Int16(bitPattern: UInt16(voice[index]) | UInt16(voice[index + 1]) << 8)
            let b = Int16(bitPattern: UInt16(background[index]) | UInt16(background[index + 1]) << 8)
            var value = Int16(clamping: Int(a) + Int(b)).littleEndian
            withUnsafeBytes(of: &value) { mixed.append(contentsOf: $0) }
        }
        let events = detector.accept(mixed + noise(150))
        XCTAssertTrue(events.contains(.started))
        XCTAssertTrue(
            events.contains {
                if case .ended = $0 { return true }
                return false
            },
            "Returning to background noise after speech must submit the turn")
    }
    func testSilenceAndShortClicksNeverStartATurn() {
        let detector = SpeechTurnDetector()
        XCTAssertEqual(detector.accept(quiet(200)), [])
        XCTAssertEqual(detector.accept(voiced(3)), [])
        XCTAssertEqual(detector.accept(quiet(100)), [])
        XCTAssertFalse(detector.speaking)
    }
    func testStartsBeforeTheUtteranceEndsAndAllowsOrdinaryPauses() {
        let detector = SpeechTurnDetector()
        _ = detector.accept(quiet(400))
        XCTAssertEqual(detector.accept(voiced(30)), [.started])
        XCTAssertEqual(detector.accept(quiet(35)), [], "A short thinking pause must not submit the turn")
        XCTAssertEqual(detector.accept(voiced(30)), [])
        let events = detector.accept(quiet(75))
        XCTAssertEqual(events.count, 1)
        guard case .ended(let data) = events.first else { return XCTFail("Expected one automatic speech turn") }
        XCTAssertLessThan(data.count, 48000 * 3, "Do not upload the long wait before speech")
        XCTAssertFalse(detector.speaking)
    }
    func testArbitraryChunkBoundariesAndConsecutiveTurns() {
        let one = voiced(45) + quiet(75)
        let input = one + one
        let whole = SpeechTurnDetector()
        let split = SpeechTurnDetector()
        let expected = whole.accept(input)
        var actual: [SpeechTurnDetector.Event] = []
        for offset in stride(from: 0, to: input.count, by: 773) {
            actual += split.accept(input.subdata(in: offset..<min(offset + 773, input.count)))
        }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 4)
    }
    func testLongSpeechIsBoundedAtSixtySeconds() {
        let detector = SpeechTurnDetector()
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
