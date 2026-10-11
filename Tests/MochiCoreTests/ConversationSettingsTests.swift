import MochiKernel
import XCTest

@testable import MochiCore

final class ConversationSettingsTests: XCTestCase {
    func testPatchTrimsValidatesAndAppliesAllOrNothing() throws {
        var chat = Conversation()
        chat.instructions = "Original"
        chat.characterName = "Loki"
        try ConversationSettingsPatch(
            instructions: "  Interview me  ", characterName: .set("  Sam "), speed: .set(0.8), coaching: .gentle
        ).apply(to: &chat)
        XCTAssertEqual(chat.instructions, "Interview me")
        XCTAssertEqual(chat.characterName, "Sam")
        XCTAssertEqual(chat.preferences.speed, 0.8)
        XCTAssertEqual(chat.preferences.coaching, .gentle)
        let before = chat
        XCTAssertThrowsError(
            try ConversationSettingsPatch(instructions: "Changed", characterName: .set("Bad\nName")).apply(to: &chat))
        XCTAssertEqual(chat.instructions, before.instructions)
        XCTAssertEqual(chat.characterName, before.characterName)
        XCTAssertThrowsError(try ConversationSettingsPatch(speed: .set(3)).apply(to: &chat))
        XCTAssertEqual(chat.preferences, before.preferences)
        try ConversationSettingsPatch(characterName: .clear, speed: .clear).apply(to: &chat)
        XCTAssertNil(chat.characterName)
        XCTAssertNil(chat.preferences.speed)
    }

    func testFailedPatchLeavesEvenAClassConformerUntouched() {
        var settings = SharedSettings()
        let patch = ConversationSettingsPatch(
            instructions: "After", characterName: .set("Bea"), speed: .set(9), coaching: .direct)
        XCTAssertThrowsError(try patch.apply(to: &settings))
        XCTAssertEqual(settings.instructions, "Before")
        XCTAssertEqual(settings.characterName, "Ava")
        XCTAssertEqual(settings.preferences, ConversationPreferences())
        XCTAssertNoThrow(try ConversationSettingsPatch(characterName: .clear, speed: .set(1.2)).apply(to: &settings))
        XCTAssertNil(settings.characterName)
        XCTAssertEqual(settings.preferences.speed, 1.2)
    }

    private final class SharedSettings: ConversationSettingsHolder {
        var instructions = "Before"
        var characterName: String? = "Ava"
        var preferences = ConversationPreferences()
    }
}
