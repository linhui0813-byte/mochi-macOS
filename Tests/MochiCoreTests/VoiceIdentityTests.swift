import MochiKernel
import XCTest

@testable import MochiCore

final class VoiceIdentityTests: XCTestCase {
    func testGreetingExcludesLastThreeAndHasStableName() {
        var recent: [String] = []
        for _ in 0..<100 {
            let text = VoiceIdentity.greeting(excluding: recent)
            XCTAssertTrue(VoiceIdentity.greetings.contains(text))
            XCTAssertFalse(recent.suffix(3).contains(text))
            XCTAssertTrue(text.contains("Mochi"))
            recent.append(text)
        }
    }
    func testIntroductionPersistsAndLegacyVoiceChatsAreAlreadyIntroduced() throws {
        var chat = Conversation()
        chat.voiceIntroduced = true
        XCTAssertTrue(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(chat)).voiceIntroduced)
        for hasAudio in [false, true] {
            chat.messages = [Message(role: "user", text: "hello", audio: hasAudio ? "voice.wav" : nil)]
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as! [String: Any]
            json.removeValue(forKey: "voiceIntroduced")
            let restored = try JSONDecoder().decode(
                Conversation.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(restored.voiceIntroduced, hasAudio)
        }
    }
}

extension VoiceIdentityTests {
    func testNamedGreetingNeverRepeatsTheLastThree() {
        var recent: [String] = []
        for _ in 0..<60 {
            let greeting = VoiceIdentity.namedGreeting(name: "Loki", excluding: recent)
            XCTAssertFalse(recent.suffix(3).contains(greeting.pattern))
            recent.append(greeting.pattern)
        }
    }

    func testCustomCharacterInstructionsDropTheMochiIdentityLines() {
        let legacy = VoiceIdentity.instructions
            .replacingOccurrences(of: "You are Mochi (pronounced MOH-chee),", with: "You are")
            .replacingOccurrences(of: "Your name is Mochi. ", with: "")
            .replacingOccurrences(of: "A mention of Mochi", with: "A mention of your name")
        let custom = VoiceIdentity.conversationInstructions(
            custom: "", preferences: ConversationPreferences(), characterName: "Loki")
        XCTAssertTrue(custom.contains(legacy))
        XCTAssertFalse(legacy.contains("Mochi"))
        let mochi = VoiceIdentity.conversationInstructions(
            custom: "", preferences: ConversationPreferences(), characterName: "Mochi")
        XCTAssertTrue(mochi.contains(VoiceIdentity.instructions))
    }
}
