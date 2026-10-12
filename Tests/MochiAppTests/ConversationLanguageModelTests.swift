import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp
@testable import MochiProviders

/// New conversations start in the user's language of choice, and everything in a conversation follows its language.
@MainActor final class ConversationLanguageModelTests: XCTestCase {
    private func app() -> AppModel {
        let app = makeApp(root: makeTemporaryFolder(), preferences: makePreferences())
        app.resume()
        return app
    }

    private func setLanguage(_ app: AppModel, _ language: ConversationLanguage) throws {
        try app.updateConversationSettings(try XCTUnwrap(app.selectedID), ConversationSettingsPatch(language: language))
    }

    func testNewConversationsStartInTheDefaultLanguage() throws {
        let app = app()
        XCTAssertEqual(app.settings.defaultLanguage, .english)
        app.settings.defaultLanguage = .korean
        // The open conversation is still untouched, so New Conversation reuses it, in today's default.
        app.newChat()
        XCTAssertEqual(app.conversation?.preferences.language, .korean)
        XCTAssertEqual(
            PreferencesStore(app.settings.defaults, importLegacy: false, allowExternalControl: false).defaultLanguage,
            .korean)
        app.append(Message(role: "user", text: "안녕하세요"), to: try XCTUnwrap(app.selectedID))
        app.settings.defaultLanguage = .french
        app.newChat()
        XCTAssertEqual(app.conversation?.preferences.language, .french)
        XCTAssertEqual(app.library.conversations.count, 2)
    }

    func testMatchingTheUserHasNoHelpMeSayThisOrExpressions() throws {
        let app = app()
        XCTAssertTrue(app.canHelp)
        try setLanguage(app, .match)
        XCTAssertFalse(app.canHelp)
        app.startHelp()
        XCTAssertFalse(app.practice, "Nothing to find words in")
        XCTAssertThrowsError(
            try app.tools.executeVoice(
                "save_expression", arguments: ["conversation_id": app.selectedID!.uuidString, "text": "Hi"],
                operationID: UUID()))
        XCTAssertTrue(app.library.expressions.isEmpty)
    }

    func testHelpAndExpressionsUseTheConversationsLanguage() async throws {
        let app = app()
        try setLanguage(app, .spanish)
        var instructions = ""
        app.speech.textReply = { _, request in
            instructions = request.resolvedInstructions
            return #"{"kind":"expression","text":"Necesito más tiempo."}"#
        }
        app.startHelp()
        app.help.meaning = "I need more time."
        app.translate()
        await waitUntil { !app.busy && !app.help.english.isEmpty }
        XCTAssertTrue(instructions.contains("natural spoken Spanish"))
        XCTAssertEqual(app.help.expression?.language, .spanish)
    }

    func testPractisingAnOrphanedExpressionContinuesInItsLanguage() throws {
        let app = app()
        let orphan = PracticeExpression(conversationID: UUID(), meaning: "", english: "Bonjour", language: .french)
        app.library.expressions = [orphan]
        app.openExpression(orphan)
        XCTAssertEqual(app.conversation?.preferences.language, .french)
        app.leavePractice()
    }

    func testAssistantsReadAndSetTheLanguage() throws {
        let app = app()
        let id = try XCTUnwrap(app.selectedID).uuidString
        _ = try app.tools.executeVoice(
            "set_conversation_preferences", arguments: ["conversation_id": id, "language": "ja"], operationID: UUID())
        XCTAssertEqual(app.conversation?.preferences.language, .japanese)
        let session = try app.tools.execute("get_session", arguments: [:], origin: .voice)
        XCTAssertEqual(session["language"] as? String, "ja")
        XCTAssertThrowsError(
            try app.tools.executeVoice(
                "set_conversation_preferences", arguments: ["conversation_id": id, "language": "klingon"],
                operationID: UUID()))
    }

    func testAConversationOpensWithAGreetingInItsLanguage() async throws {
        let app = app()
        try setLanguage(app, .german)
        app.media.permission = { true }
        app.media.record = { _ in }
        app.audio.makePlayer = { _ in throw CancellationError() }
        var spoken = ""
        app.speech.referenceAudio = { text, _, root, _ in
            spoken = text
            return root.appendingPathComponent("greeting.wav")
        }
        app.toggleConversationVoice()
        await waitUntil { !spoken.isEmpty && app.conversation?.voiceIntroduced == true }
        XCTAssertTrue(
            Greetings.patterns(.german).map { $0.replacingOccurrences(of: "{name}", with: "Mochi") }.contains(spoken),
            spoken)
        XCTAssertEqual(app.conversation?.messages.first?.text, spoken)
        app.stop()
    }
}
