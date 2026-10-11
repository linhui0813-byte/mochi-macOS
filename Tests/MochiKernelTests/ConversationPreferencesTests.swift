import MochiKernel
import XCTest

final class ConversationPreferencesTests: XCTestCase {
    func testPartialAndUnknownPreferencesDecodeSafely() throws {
        for json in ["{}", "{\"coaching\":\"future\"}", "{\"speed\":10}", "{\"speed\":\"bad\"}"] {
            let preferences = try JSONDecoder().decode(ConversationPreferences.self, from: Data(json.utf8))
            XCTAssertEqual(preferences.coaching, .natural)
            XCTAssertNil(preferences.speed)
        }
    }

    func testSpeedRuleIsSharedByDecodingAndValidation() throws {
        for speed in [0.25, 1.5, 1.0] { XCTAssertTrue(ConversationPreferences.isValidSpeed(speed)) }
        for speed in [0.2, 1.6, .nan, .infinity] { XCTAssertFalse(ConversationPreferences.isValidSpeed(speed)) }
        let decoded = try JSONDecoder().decode(
            ConversationPreferences.self, from: Data(#"{"speed": 2, "coaching": 5}"#.utf8))
        XCTAssertNil(decoded.speed)
        XCTAssertEqual(decoded.coaching, .natural)
    }
}
