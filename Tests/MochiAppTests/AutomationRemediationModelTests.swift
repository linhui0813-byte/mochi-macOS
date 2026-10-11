import MochiAutomation
import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp

final class AutomationRemediationModelTests: XCTestCase {
    @MainActor private func controlledApp() -> AppModel {
        let app = makeApp(root: makeTemporaryFolder())
        app.externalControlEnabled = true
        addTeardownBlock { @MainActor in app.externalControlEnabled = false }
        return app
    }

    // MARK: Template creation retries (L1)

    @MainActor func testRetriedTemplateCreationWithTheSameKeyCreatesOneTemplate() throws {
        let app = controlledApp()
        let arguments: [String: Any] = [
            "title": "Interview", "instructions": "Ask one question at a time.", "idempotency_key": "retry-1",
        ]
        let first = try app.executeTool("create_conversation_template", arguments: arguments, origin: .external)
        let second = try app.executeTool("create_conversation_template", arguments: arguments, origin: .external)
        XCTAssertEqual(app.library.conversationTemplates.count, 1)
        XCTAssertEqual(
            (first["template"] as? [String: Any])?["id"] as? String,
            (second["template"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual(second["replayed"] as? Bool, true)
        var changed = arguments
        changed["title"] = "Different"
        XCTAssertThrowsError(try app.executeTool("create_conversation_template", arguments: changed, origin: .external))
        _ = try app.executeTool(
            "create_conversation_template", arguments: ["title": "No key", "instructions": "x"], origin: .external)
        _ = try app.executeTool(
            "create_conversation_template", arguments: ["title": "No key", "instructions": "x"], origin: .external)
        XCTAssertEqual(app.library.conversationTemplates.count, 3)
    }

    // MARK: Untrusted library text (L7)

    @MainActor func testReadResultsNameTheirLibraryTextFields() throws {
        let app = controlledApp()
        let id = try XCTUnwrap(app.selectedID)
        let session = try app.executeTool("get_session", arguments: [:], origin: .external)
        XCTAssertEqual(
            Set(session["untrusted_fields"] as? [String] ?? []),
            ["title", "instructions", "character_name", "display_character_name"])
        let messages = try app.executeTool(
            "get_messages", arguments: ["conversation_id": id.uuidString], origin: .external)
        XCTAssertEqual(messages["untrusted_fields"] as? [String], ["messages.text"])
        let template = try app.executeTool(
            "get_conversation_template", arguments: ["template_id": ConversationTemplate.builtins[0].id.uuidString],
            origin: .external)
        XCTAssertTrue((template["untrusted_fields"] as? [String] ?? []).contains("template.instructions"))
    }

    // MARK: One settings path (M18)

    @MainActor func testTemplateOverridesApplyBeforeTheSnapshotIsValidated() throws {
        let app = controlledApp()
        var broken = ConversationTemplate(title: "Recovered", characterName: "Bad\nName", instructions: "Hello")
        broken.revision = UUID().uuidString
        app.library.conversationTemplates = [broken]
        try app.store.save(app.library)
        let revision = app.controlRevision
        XCTAssertThrowsError(
            try app.executeTool(
                "create_conversation", arguments: ["template_id": broken.id.uuidString, "expected_revision": revision],
                origin: .external))
        let result = try app.executeTool(
            "create_conversation",
            arguments: [
                "template_id": broken.id.uuidString, "character_name": "  Sam ",
                "expected_revision": app.controlRevision,
            ], origin: .external)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(app.conversation?.characterName, "Sam")
        XCTAssertEqual(app.conversation?.sourceTemplateID, broken.id)
    }
    @MainActor func testSheetAndAssistantShareValidationAndKeepOversizedLegacyInstructions() throws {
        let app = controlledApp()
        let id = try XCTUnwrap(app.selectedID)
        let legacy = String(repeating: "文", count: 9000)
        app.library.conversations[0].instructions = legacy
        try app.store.save(app.library)
        var preferences = ConversationPreferences()
        preferences.coaching = .direct
        XCTAssertTrue(
            app.setConversationInstructions(id, instructions: legacy, preferences: preferences, characterName: " Loki ")
        )
        XCTAssertEqual(app.conversation?.instructions, legacy)
        XCTAssertEqual(app.conversation?.characterName, "Loki")
        XCTAssertFalse(
            app.setConversationInstructions(
                id, instructions: legacy, preferences: preferences, characterName: "Bad\nName"))
        XCTAssertEqual(app.conversation?.characterName, "Loki")
        XCTAssertThrowsError(
            try app.executeTool(
                "set_conversation_instructions",
                arguments: [
                    "conversation_id": id.uuidString, "character_name": "Bad\nName",
                    "expected_revision": app.controlRevision,
                ], origin: .external))
        XCTAssertEqual(app.conversation?.characterName, "Loki")
        _ = try app.executeTool(
            "set_conversation_preferences",
            arguments: ["conversation_id": id.uuidString, "speed": 0.9, "expected_revision": app.controlRevision],
            origin: .external)
        XCTAssertEqual(app.conversation?.preferences.speed, 0.9)
        XCTAssertEqual(app.conversation?.preferences.coaching, .direct)
    }
}
