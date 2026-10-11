import MochiCore
import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiApp
@testable import MochiProviders

final class ConversationTemplateModelTests: XCTestCase {
    @MainActor func testMCPIndependentCatalogAndImmutableSnapshots() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences())
        app.externalControlEnabled = true
        app.selectedID = nil
        _ = app.turn.begin(.generating)
        app.error = "Keep provider error"
        app.notice = "Keep notice"
        let created = try app.tools.execute(
            "create_conversation_template", arguments: ["title": "Loki", "character_name": "Loki"], origin: .external)
        let t = try XCTUnwrap(created["template"] as? [String: Any])
        let id = try XCTUnwrap(t["id"] as? String)
        let rev = try XCTUnwrap(t["template_revision"] as? String)
        XCTAssertEqual(app.error, "Keep provider error")
        XCTAssertEqual(app.notice, "Keep notice")
        XCTAssertEqual(app.turn.activity, .generating)
        let updated = try app.tools.execute(
            "update_conversation_template",
            arguments: ["template_id": id, "expected_template_revision": rev, "instructions": "Discuss books"],
            origin: .external)
        XCTAssertThrowsError(
            try app.tools.execute(
                "delete_conversation_template", arguments: ["template_id": id, "expected_template_revision": rev],
                origin: .external))
        let newRev = (updated["template"] as! [String: Any])["template_revision"] as! String
        _ = app.turn.finish(app.turn.epoch)
        let chat = try app.tools.execute(
            "create_conversation", arguments: ["template_id": id, "expected_revision": app.tools.revision],
            origin: .external)
        XCTAssertNotNil(chat["conversation_id"])
        XCTAssertEqual(app.conversation?.characterName, "Loki")
        _ = try app.tools.execute(
            "delete_conversation_template", arguments: ["template_id": id, "expected_template_revision": newRev],
            origin: .external)
        XCTAssertEqual(app.conversation?.instructions, "Discuss books")
        XCTAssertTrue(app.library.conversationTemplates.isEmpty)
    }
    @MainActor func testNameOnlyMutationPreservesOversizedInstructionsAndNoOpRevision() throws {
        let app = makeApp(demo: true)
        app.resume()
        app.externalControlEnabled = true
        let id = try XCTUnwrap(app.selectedID)
        let index = try XCTUnwrap(app.library.conversations.firstIndex(where: { $0.id == id }))
        app.library.conversations[index].instructions = String(repeating: "x", count: 9000)
        _ = try app.tools.execute(
            "set_conversation_instructions",
            arguments: [
                "conversation_id": id.uuidString, "expected_revision": app.tools.revision, "character_name": "Loki",
            ], origin: .external)
        XCTAssertEqual(app.conversation?.instructions.count, 9000)
        XCTAssertEqual(app.conversation?.characterName, "Loki")
        let t = try app.templates.create(.init(title: "Recall", settings: .init(instructions: "Ask me words")))
        let unchanged = try app.templates.update(
            id: t.id, revision: t.revision, .init(settings: .init(instructions: "Ask me words")))
        XCTAssertEqual(unchanged.revision, t.revision)
    }
    @MainActor func testFailedTemplateSavePreservesConversationAndDraft() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences())
        app.error = "Existing error"
        let before = app.selectedID
        try Data("broken".utf8).write(to: app.store.file)
        XCTAssertThrowsError(
            try app.templates.create(.init(title: "Loki", settings: .init(characterName: .set("Loki")))))
        XCTAssertTrue(app.library.conversationTemplates.isEmpty)
        XCTAssertEqual(app.error, "Existing error")
        XCTAssertEqual(app.selectedID, before)
    }
}

extension ConversationTemplateModelTests {
    @MainActor func testCatalogPagingAndOpenPickerMutation() throws {
        let app = makeApp(demo: true)
        app.resume()
        app.externalControlEnabled = true
        app.openTemplatePicker()
        app.library.conversationTemplates = (0..<120).map {
            ConversationTemplate(title: String(format: "T%03d", $0), instructions: "Discuss topics")
        }
        var ids: Set<String> = []
        var offset = 0
        let revision = app.tools.templateCatalogRevision
        repeat {
            let page = try app.tools.execute(
                "list_conversation_templates",
                arguments: ["limit": 20, "offset": offset, "expected_catalog_revision": revision], origin: .external)
            let items = page["templates"] as! [[String: Any]]
            for item in items { XCTAssertTrue(ids.insert(item["id"] as! String).inserted) }
            if let next = page["next_offset"] as? Int {
                XCTAssertGreaterThan(next, offset)
                offset = next
            } else {
                break
            }
        } while true
        XCTAssertEqual(ids.count, 126)
        _ = try app.tools.execute(
            "create_conversation_template", arguments: ["title": "New", "character_name": "Loki"], origin: .external)
        XCTAssertEqual(app.customization.templatePresentation, .picker)
        XCTAssertThrowsError(
            try app.tools.execute(
                "list_conversation_templates", arguments: ["expected_catalog_revision": revision], origin: .external))
        XCTAssertThrowsError(
            try app.tools.execute(
                "create_conversation", arguments: ["expected_revision": app.tools.revision], origin: .external))
    }
    @MainActor func testPreviewSurvivesSourceDeletionAndSaveAsPreservesNilDraft() throws {
        let app = makeApp(demo: true)
        app.resume()
        let source = try app.templates.create(
            .init(title: "Scenario", settings: .init(instructions: "Your name is Sam")))
        app.openTemplatePicker()
        let snapshot = source
        try app.templates.delete(id: source.id, revision: source.revision)
        let id = try app.startTemplateSnapshot(snapshot)
        XCTAssertEqual(app.selectedID, id)
        XCTAssertNil(app.conversation?.characterName)
        XCTAssertEqual(app.conversation?.sourceTemplateID, source.id)
        app.customization.instructionsID = id
        app.saveConversationAsTemplate(
            id,
            draft: ConversationSettingsDraft(
                id: id, instructions: "Unsaved", characterName: nil, preferences: ConversationPreferences()))
        XCTAssertEqual(app.customization.templateDraft?.value.instructions, "Unsaved")
        XCTAssertNil(app.customization.templateDraft?.value.characterName)
        app.customization.closeTemplateEditor()
        XCTAssertEqual(app.customization.retainedInstructionsDraft?.instructions, "Unsaved")
        XCTAssertEqual(app.customization.instructionsID, id)
    }
    @MainActor func testReplyUsesCapturedSpeakerAndIdentity() async throws {
        let app = makeApp(demo: true)
        let gate = TestGate()
        app.resume()
        let id = try XCTUnwrap(app.selectedID)
        XCTAssertTrue(
            app.setConversationInstructions(
                id, instructions: "Discuss books", preferences: ConversationPreferences(), characterName: "Loki"))
        var started = false
        app.speech.conversationReply = { _, request, callbacks in
            XCTAssertEqual(request.characterName, "Loki")
            started = true
            await gate.wait()
            var reply = RealtimeAccumulator()
            reply.text = "Hello"
            try callbacks.response(reply)
        }
        app.draft = "Hi"
        app.send()
        await waitUntil { started }
        XCTAssertTrue(started)
        let index = try XCTUnwrap(app.library.conversations.firstIndex(where: { $0.id == id }))
        app.library.conversations[index].characterName = "Sam"
        await gate.release()
        await waitUntil { app.conversation?.messages.last?.role == "assistant" }
        XCTAssertEqual(app.conversation?.messages.last?.speakerName, "Loki")
        app.stop()
    }
    @MainActor func testTemplateCapAndBuiltInMutationAndNoNetworkOnStart() throws {
        let app = makeApp(demo: true)
        app.resume()
        app.library.conversationTemplates = (0..<200).map {
            ConversationTemplate(title: "T\($0)", instructions: "Discuss")
        }
        XCTAssertThrowsError(
            try app.templates.create(.init(title: "More", settings: .init(characterName: .set("Loki")))))
        let builtin = ConversationTemplate.builtins[0]
        XCTAssertThrowsError(
            try app.templates.update(id: builtin.id, revision: builtin.revision, .init(title: "Overwrite")))
        XCTAssertThrowsError(try app.templates.delete(id: builtin.id, revision: builtin.revision))
        app.speech.conversationReply = { _, _, _ in XCTFail("Starting a template must not send a request") }
        app.media.permission = {
            XCTFail("Starting a template must not request microphone")
            return false
        }
        let before = app.library.conversations.count
        _ = try app.startTemplateSnapshot(builtin)
        XCTAssertEqual(app.library.conversations.count, before + 1)
        XCTAssertTrue(app.conversation!.messages.isEmpty)
    }
}

extension ConversationTemplateModelTests {
    @MainActor func testEditorTrimsCharacterName() throws {
        let app = makeApp(demo: true)
        app.resume()
        let id = try XCTUnwrap(app.selectedID)
        XCTAssertTrue(
            app.setConversationInstructions(
                id, instructions: "", preferences: ConversationPreferences(), characterName: "  Loki \n"))
        XCTAssertEqual(app.conversation?.characterName, "Loki")
        XCTAssertFalse(
            app.setConversationInstructions(
                id, instructions: "", preferences: ConversationPreferences(), characterName: "   "))
        XCTAssertEqual(app.conversation?.characterName, "Loki")
    }
    @MainActor func testPickerPreviewEditsSurviveDuplicateCancel() {
        let app = makeApp(demo: true)
        app.resume()
        app.openTemplatePicker()
        var preview = ConversationTemplate.builtins[1]
        preview.instructions = "Customized before duplicating"
        app.customization.templateDraft = TemplateEditorDraft(
            value: preview, editingID: nil, expectedRevision: preview.revision)
        app.customization.editTemplate(preview, duplicate: true)
        XCTAssertEqual(app.customization.templatePresentation, .editor)
        app.customization.closeTemplateEditor()
        XCTAssertEqual(app.customization.templatePresentation, .picker)
        XCTAssertEqual(app.customization.templateDraft?.value.instructions, "Customized before duplicating")
        app.customization.templatePresentation = nil
        app.customization.templateDraft = nil
        app.openTemplateManager()
        app.customization.editTemplate(nil)
        app.customization.closeTemplateEditor()
        XCTAssertEqual(app.customization.templatePresentation, .manager)
        XCTAssertNil(app.customization.templateDraft)
    }
    @MainActor func testTemplateCreationNeverReusesPristineChatButBlankCreationDoes() throws {
        let app = makeApp(demo: true)
        app.resume()
        app.externalControlEnabled = true
        app.newChat()
        let pristine = try XCTUnwrap(app.selectedID)
        XCTAssertTrue(app.conversation?.isPristine == true)
        let index = try XCTUnwrap(app.library.conversations.firstIndex(where: { $0.id == pristine }))
        app.library.conversations[index].pinned = true
        let builtin = ConversationTemplate.builtins[3]
        let created = try app.tools.execute(
            "create_conversation",
            arguments: ["template_id": builtin.id.uuidString, "expected_revision": app.tools.revision],
            origin: .external)
        XCTAssertNotEqual(created["conversation_id"] as? String, pristine.uuidString)
        XCTAssertTrue(app.library.conversations.first { $0.id == pristine }?.isPristine == true)
        XCTAssertEqual(app.conversation?.sourceTemplateID, builtin.id)
        XCTAssertEqual(app.conversation?.characterName, "Mochi")
        _ = try app.tools.execute(
            "open_conversation",
            arguments: ["conversation_id": pristine.uuidString, "expected_revision": app.tools.revision],
            origin: .external)
        let blank = try app.tools.execute(
            "create_conversation",
            arguments: [
                "character_name": "Loki", "coaching": "direct", "speed": 0.8, "expected_revision": app.tools.revision,
            ], origin: .external)
        XCTAssertEqual(blank["conversation_id"] as? String, pristine.uuidString)
        let reused = try XCTUnwrap(app.conversation)
        XCTAssertTrue(reused.pinned)
        XCTAssertEqual(reused.characterName, "Loki")
        XCTAssertEqual(reused.preferences.coaching, .direct)
        XCTAssertEqual(reused.preferences.speed, 0.8)
    }
}

extension ConversationTemplateModelTests {
    @MainActor func testUIStaleDraftAndSessionMetadataAndOverrideRecovery() throws {
        let app = makeApp(demo: true)
        app.resume()
        app.externalControlEnabled = true
        let original = try app.templates.create(.init(title: "Loki", settings: .init(characterName: .set("Loki"))))
        app.openTemplateManager()
        app.customization.editTemplate(original)
        app.customization.templateDraft?.value.instructions = "Unsaved editor changes"
        _ = try app.templates.update(
            id: original.id, revision: original.revision, .init(settings: .init(instructions: "Concurrent update")))
        XCTAssertThrowsError(
            try app.templates.update(
                id: original.id, revision: app.customization.templateDraft!.expectedRevision!,
                .init(settings: .init(instructions: app.customization.templateDraft!.value.instructions))))
        XCTAssertEqual(app.customization.templateDraft?.value.instructions, "Unsaved editor changes")
        app.customization.templatePresentation = nil
        app.customization.templateDraft = nil
        let i = app.library.conversationTemplates.firstIndex(where: { $0.id == original.id })!
        app.library.conversationTemplates[i].instructions = String(repeating: "x", count: 9000)
        _ = try app.tools.execute(
            "create_conversation",
            arguments: [
                "template_id": original.id.uuidString, "expected_revision": app.tools.revision,
                "instructions": "Corrected for this conversation",
            ], origin: .external)
        let session = try app.tools.execute("get_session", arguments: [:], origin: .external)
        XCTAssertEqual(session["character_name"] as? String, "Loki")
        XCTAssertEqual(session["display_character_name"] as? String, "Loki")
        XCTAssertEqual(session["source_template_id"] as? String, original.id.uuidString)
        XCTAssertEqual(session["source_template_revision"] as? String, app.library.conversationTemplates[i].revision)
        XCTAssertEqual(app.library.conversationTemplates[i].instructions.count, 9000)
    }
    @MainActor func testNameOnlyUIEditPreservesOversizedTextAndOmittedName() throws {
        let app = makeApp(demo: true)
        app.resume()
        let id = try XCTUnwrap(app.selectedID)
        let i = app.library.conversations.firstIndex(where: { $0.id == id })!
        let text = "  " + String(repeating: "x", count: 9000) + "  "
        app.library.conversations[i].instructions = text
        XCTAssertTrue(
            app.setConversationInstructions(
                id, instructions: text, preferences: ConversationPreferences(), characterName: "Loki"))
        XCTAssertEqual(app.conversation?.instructions, text)
        XCTAssertTrue(
            app.setConversationInstructions(
                id, instructions: "New small instructions", preferences: ConversationPreferences()))
        XCTAssertEqual(app.conversation?.characterName, "Loki")
    }
    @MainActor func testOversizedMetadataPagesStayBoundedAndProgress() throws {
        let app = makeApp(demo: true)
        app.resume()
        app.externalControlEnabled = true
        app.library.conversationTemplates = (0..<80).map { _ in
            var t = ConversationTemplate(
                title: String(repeating: "\u{0001}", count: 160),
                description: String(repeating: "\u{0001}", count: 500),
                characterName: String(repeating: "\u{0001}", count: 80), instructions: "Discuss")
            t.description += String(repeating: "z", count: 10000)
            return t
        }
        var offset = 0
        var seen = 0
        repeat {
            let page = try app.tools.execute(
                "list_conversation_templates", arguments: ["origin": "user", "limit": 100, "offset": offset],
                origin: .external)
            XCTAssertLessThan(try JSONSerialization.data(withJSONObject: page).count, 110000)
            seen += (page["templates"] as! [[String: Any]]).count
            if let next = page["next_offset"] as? Int {
                XCTAssertGreaterThan(next, offset)
                offset = next
            } else {
                break
            }
        } while true
        XCTAssertEqual(seen, 80)
    }
    @MainActor func testInvalidRecoveredNameIsFlaggedWithoutSendingOrLosingDraft() throws {
        let app = makeApp(demo: true)
        app.resume()
        app.externalControlEnabled = true
        let id = try XCTUnwrap(app.selectedID)
        let i = app.library.conversations.firstIndex(where: { $0.id == id })!
        app.library.conversations[i].characterName = "\nInvalid"
        app.speech.conversationReply = { _, _, _ in XCTFail("Must not send invalid identity") }
        app.draft = "Keep this"
        app.send()
        XCTAssertEqual(app.draft, "Keep this")
        XCTAssertNotNil(app.error)
        XCTAssertTrue(app.conversation!.characterNameNeedsReview)
        let session = try app.tools.execute("get_session", arguments: [:], origin: .external)
        XCTAssertEqual(session["character_name_needs_review"] as? Bool, true)
        XCTAssertEqual(session["display_character_name"] as? String, "Companion")
        XCTAssertTrue(
            app.setConversationInstructions(
                id, instructions: app.conversation!.instructions, preferences: ConversationPreferences(),
                characterName: "Loki"))
        XCTAssertFalse(app.conversation!.characterNameNeedsReview)
    }
}

extension ConversationTemplateModelTests {
    @MainActor func testRetryRejectsNameNeedingReviewBeforeProvider() throws {
        let app = makeApp(demo: true)
        app.resume()
        let id = try XCTUnwrap(app.selectedID)
        let index = try XCTUnwrap(app.library.conversations.firstIndex(where: { $0.id == id }))
        app.library.conversations[index].messages = [Message(role: "user", text: "Hello")]
        app.library.conversations[index].characterName = "Bad\nName"
        app.speech.conversationReply = { _, _, _ in XCTFail("A name needing review must not reach the provider") }
        XCTAssertTrue(app.canRetry)
        app.retryReply()
        XCTAssertEqual(app.turn.activity, .idle)
        XCTAssertNotNil(app.error)
        XCTAssertEqual(app.conversation?.messages.count, 1)
    }
    @MainActor func testPickerValidatesCopiedSettingsWhileEditorRequiresWritableTemplate() {
        let app = makeApp(demo: true)
        app.resume()
        app.openTemplatePicker()
        var recovered = ConversationTemplate(title: "Recovered", instructions: "Discuss books")
        recovered.description = String(repeating: "d", count: 600)
        app.customization.templateDraft = TemplateEditorDraft(
            value: recovered, editingID: nil, expectedRevision: recovered.revision)
        XCTAssertNil(
            app.customization.templateDraftIssue, "Catalog-only metadata must not block starting from copied settings")
        app.customization.templateDraft?.value.instructions = String(repeating: "x", count: 9000)
        XCTAssertNotNil(app.customization.templateDraftIssue)
        app.customization.templateDraft?.value.instructions = "Discuss books"
        app.customization.templatePresentation = .manager
        XCTAssertNotNil(
            app.customization.templateDraftIssue, "Manager/editor explain why a recovery template needs review")
    }
}

extension ConversationTemplateModelTests {
    @MainActor func testRetriedTemplateCreationWithTheSameKeyCreatesOneTemplate() throws {
        let app = controlledApp()
        let arguments: [String: Any] = [
            "title": "Interview", "instructions": "Ask one question at a time.", "idempotency_key": "retry-1",
        ]
        let first = try app.tools.execute("create_conversation_template", arguments: arguments, origin: .external)
        let second = try app.tools.execute("create_conversation_template", arguments: arguments, origin: .external)
        XCTAssertEqual(app.library.conversationTemplates.count, 1)
        XCTAssertEqual(
            (first["template"] as? [String: Any])?["id"] as? String,
            (second["template"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual(second["replayed"] as? Bool, true)
        var changed = arguments
        changed["title"] = "Different"
        XCTAssertThrowsError(
            try app.tools.execute("create_conversation_template", arguments: changed, origin: .external))
        _ = try app.tools.execute(
            "create_conversation_template", arguments: ["title": "No key", "instructions": "x"], origin: .external)
        _ = try app.tools.execute(
            "create_conversation_template", arguments: ["title": "No key", "instructions": "x"], origin: .external)
        XCTAssertEqual(app.library.conversationTemplates.count, 3)
    }

    @MainActor func testTemplateOverridesApplyBeforeTheSnapshotIsValidated() throws {
        let app = controlledApp()
        var broken = ConversationTemplate(title: "Recovered", characterName: "Bad\nName", instructions: "Hello")
        broken.revision = UUID().uuidString
        app.library.conversationTemplates = [broken]
        try app.store.save(app.library)
        let revision = app.tools.revision
        XCTAssertThrowsError(
            try app.tools.execute(
                "create_conversation", arguments: ["template_id": broken.id.uuidString, "expected_revision": revision],
                origin: .external))
        let result = try app.tools.execute(
            "create_conversation",
            arguments: [
                "template_id": broken.id.uuidString, "character_name": "  Sam ",
                "expected_revision": app.tools.revision,
            ], origin: .external)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(app.conversation?.characterName, "Sam")
        XCTAssertEqual(app.conversation?.sourceTemplateID, broken.id)
    }

    @MainActor func testTemplateResultsNameTheirOwnLibraryTextFields() throws {
        let app = makeApp(root: makeTemporaryFolder())
        let list = try app.tools.executeTemplateTool(.listConversationTemplates, arguments: [:])
        XCTAssertEqual(
            list["untrusted_fields"] as? [String],
            ["templates.title", "templates.description", "templates.character_name"])
        XCTAssertFalse((list["templates"] as? [[String: Any]] ?? []).isEmpty)
        let single = try app.tools.executeTemplateTool(
            .getConversationTemplate, arguments: ["template_id": ConversationTemplate.builtins[0].id.uuidString])
        XCTAssertEqual(
            Set(single["untrusted_fields"] as? [String] ?? []),
            ["template.title", "template.description", "template.character_name", "template.instructions"])
    }

    @MainActor private func controlledApp() -> AppModel {
        let app = makeApp(root: makeTemporaryFolder())
        app.externalControlEnabled = true
        addTeardownBlock { @MainActor in app.externalControlEnabled = false }
        return app
    }
}
