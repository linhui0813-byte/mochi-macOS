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

    func testNewSettingsKeepSetAndClear() throws {
        var chat = Conversation()
        try ConversationSettingsPatch(
            personality: "  Calm and wry  ", greeting: "  Where shall we begin?  ",
            phrases: ["  Add a twist. ", "", "   ", "Give it an ending."], voice: .set("sage")
        ).apply(to: &chat)
        XCTAssertEqual(chat.personality, "Calm and wry")
        XCTAssertEqual(chat.greeting, "Where shall we begin?")
        XCTAssertEqual(chat.phrases, ["Add a twist.", "Give it an ending."])
        XCTAssertEqual(chat.preferences.voice, "sage")
        // Omitted fields are kept.
        try ConversationSettingsPatch(coaching: .gentle).apply(to: &chat)
        XCTAssertEqual(chat.personality, "Calm and wry")
        XCTAssertEqual(chat.phrases.count, 2)
        XCTAssertEqual(chat.preferences.voice, "sage")
        // Empty text and an empty list clear; clearing the voice returns to the Settings voice.
        try ConversationSettingsPatch(personality: "", greeting: " ", phrases: [], voice: .clear).apply(to: &chat)
        XCTAssertEqual(chat.personality, "")
        XCTAssertEqual(chat.greeting, "")
        XCTAssertEqual(chat.phrases, [])
        XCTAssertNil(chat.preferences.voice)
    }

    func testInvalidNewSettingsChangeNothing() {
        var chat = Conversation()
        chat.instructions = "Keep"
        let before = chat
        let invalid: [ConversationSettingsPatch] = [
            .init(instructions: "Changed", greeting: "Two\nlines"),
            .init(instructions: "Changed", greeting: String(repeating: "g", count: 161)),
            .init(instructions: "Changed", phrases: (1...7).map { "Phrase \($0)" }),
            .init(instructions: "Changed", phrases: [String(repeating: "p", count: 101)]),
            .init(instructions: "Changed", phrases: ["Line\u{202E}break"]),
            .init(instructions: "Changed", personality: String(repeating: "x", count: 2001)),
            .init(instructions: "Changed", voice: .set("future_voice")),
        ]
        for patch in invalid {
            XCTAssertThrowsError(try patch.apply(to: &chat), "\(patch)")
            XCTAssertEqual(chat.instructions, before.instructions)
            XCTAssertEqual(chat.greeting, before.greeting)
            XCTAssertEqual(chat.phrases, before.phrases)
            XCTAssertEqual(chat.preferences, before.preferences)
        }
        XCTAssertNoThrow(try ConversationSettingsPatch(phrases: (1...6).map { "Phrase \($0)" }).apply(to: &chat))
    }

    /// A voice this version does not know was imported or written by a newer Mochi: it is kept through unrelated
    /// edits, and only a new choice must be supported.
    func testUnknownStoredVoiceSurvivesUnrelatedEdits() throws {
        var chat = Conversation()
        chat.preferences.voice = "future_voice"
        try ConversationSettingsPatch(instructions: "Talk about books", coaching: .direct, language: .french)
            .apply(to: &chat)
        XCTAssertEqual(chat.preferences.voice, "future_voice")
        XCTAssertNil(chat.preferences.supportedVoice)
        var template = ConversationTemplate(title: "Imported", instructions: "x")
        template.preferences.voice = "future_voice"
        XCTAssertNoThrow(try template.validateForWrite())
        let edited = try template.applying(.init(description: "Now described"))
        XCTAssertEqual(edited.preferences.voice, "future_voice")
        XCTAssertEqual(try template.conversation().preferences.voice, "future_voice")
    }

    /// The editors save what changed and nothing else, so text kept from before a limit, or a voice this version
    /// does not know, is neither validated nor rewritten when the user changes something else.
    func testChangingPatchHoldsOnlyWhatChanged() throws {
        var current = Conversation()
        current.instructions = String(repeating: "x", count: ConversationInstructions.maxCharacters + 10)
        current.personality = String(repeating: "p", count: ConversationPersonality.maxCharacters + 10)
        current.preferences.voice = "future_voice"
        current.characterName = "Ava"
        var target = current
        target.greeting = "Hello there."
        target.preferences.coaching = .gentle
        let patch = ConversationSettingsPatch(changing: current, to: target)
        XCTAssertEqual(patch, ConversationSettingsPatch(coaching: .gentle, greeting: "Hello there."))
        var applied = current
        try patch.apply(to: &applied)
        XCTAssertEqual(applied.instructions, current.instructions)
        XCTAssertEqual(applied.personality, current.personality)
        XCTAssertEqual(applied.preferences.voice, "future_voice")
        XCTAssertEqual(applied.greeting, "Hello there.")
        target = current
        target.characterName = nil
        target.preferences.voice = nil
        target.preferences.speed = 0.9
        XCTAssertEqual(
            ConversationSettingsPatch(changing: current, to: target),
            ConversationSettingsPatch(characterName: .clear, speed: .set(0.9), voice: .clear))
        XCTAssertTrue(ConversationSettingsPatch(changing: current, to: current).isEmpty)
    }

    /// One list copies every setting. A holder declares exactly the protocol's settings, so a new setting that
    /// `adoptSettings` forgets fails here, not in a user's conversation.
    func testAdoptSettingsCopiesEverySetting() {
        let source = SharedSettings()
        source.instructions = "Interview me"
        source.characterName = "Bea"
        source.personality = "Wry"
        source.greeting = "Ready?"
        source.phrases = ["Next question."]
        source.preferences.speed = 0.8
        source.preferences.coaching = .direct
        source.preferences.language = .japanese
        source.preferences.voice = "ash"
        var copy = SharedSettings()
        copy.adoptSettings(from: source)
        let original = Mirror(reflecting: source).children.map { "\($0.label ?? ""): \($0.value)" }
        XCTAssertEqual(Mirror(reflecting: copy).children.map { "\($0.label ?? ""): \($0.value)" }, original)
        XCTAssertEqual(original.count, 6)
        var chat = Conversation()
        chat.adoptSettings(from: source)
        XCTAssertEqual(chat.instructions, "Interview me")
        XCTAssertEqual(chat.characterName, "Bea")
        XCTAssertEqual(chat.personality, "Wry")
        XCTAssertEqual(chat.greeting, "Ready?")
        XCTAssertEqual(chat.phrases, ["Next question."])
        XCTAssertEqual(chat.preferences, source.preferences)
    }

    func testPickingACharacterChangesExactlyNamePersonalityAndVoice() {
        var chat = Conversation()
        chat.instructions = "Tell a story"
        chat.greeting = "Once upon a time?"
        chat.phrases = ["Add a twist."]
        chat.preferences.speed = 0.9
        chat.preferences.language = .spanish
        chat.preferences.voice = "ash"
        let before = chat
        let pip = ConversationCharacter.builtins[2]
        chat.adoptCharacter(pip)
        XCTAssertEqual(chat.characterName, "Pip")
        XCTAssertEqual(chat.personality, pip.personality)
        XCTAssertEqual(chat.preferences.voice, pip.voice)
        XCTAssertTrue(chat.hasCharacter(pip))
        XCTAssertEqual(chat.instructions, before.instructions)
        XCTAssertEqual(chat.greeting, before.greeting)
        XCTAssertEqual(chat.phrases, before.phrases)
        XCTAssertEqual(chat.preferences.speed, before.preferences.speed)
        XCTAssertEqual(chat.preferences.language, before.preferences.language)
        // A character with no voice or personality clears them: the pick is the whole character.
        chat.adoptCharacter(ConversationCharacter.builtins[0])
        XCTAssertEqual(chat.characterName, "Mochi")
        XCTAssertEqual(chat.personality, "")
        XCTAssertNil(chat.preferences.voice)
    }

    private final class SharedSettings: ConversationSettingsHolder {
        var instructions = "Before"
        var characterName: String? = "Ava"
        var personality = ""
        var greeting = ""
        var phrases: [String] = []
        var preferences = ConversationPreferences()
    }
}
