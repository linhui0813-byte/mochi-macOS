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

    func testStoredVoiceIsKeptWhenPlausibleAndOmittedWhenUnset() throws {
        func decode(_ json: String) throws -> ConversationPreferences {
            try JSONDecoder().decode(ConversationPreferences.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"voice":"cedar"}"#).voice, "cedar")
        // A voice this version does not know is kept as stored, so nothing rewrites it silently.
        XCTAssertEqual(try decode(#"{"voice":"aurora-2"}"#).voice, "aurora-2")
        for json in [
            #"{"voice":""}"#, #"{"voice":"two words"}"#, #"{"voice":7}"#, #"{"voice":null}"#,
            "{\"voice\":\"\(String(repeating: "v", count: 65))\"}",
        ] {
            XCTAssertNil(try decode(json).voice, json)
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConversationPreferences()))
        XCTAssertNil((encoded as? [String: Any])?["voice"], "An unset voice is not written")
        var chosen = ConversationPreferences()
        chosen.voice = "sage"
        XCTAssertNotEqual(chosen, ConversationPreferences())
        XCTAssertEqual(
            try JSONDecoder().decode(ConversationPreferences.self, from: JSONEncoder().encode(chosen)), chosen)
        XCTAssertEqual(chosen.supportedVoice, .sage)
        chosen.voice = "aurora-2"
        XCTAssertNil(chosen.supportedVoice)
    }
    func testVoiceRegistryIDsArePlausible() {
        XCTAssertEqual(RealtimeVoice.allCases.count, 10)
        for voice in RealtimeVoice.allCases { XCTAssertTrue(RealtimeVoice.isPlausibleID(voice.rawValue)) }
        XCTAssertFalse(RealtimeVoice.isPlausibleID("café"))
    }
}
