import MochiAutomation
import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp

final class AuditFixG5Tests: XCTestCase {
    @MainActor func testExportKeepsRecordingsDeletedWhileItRuns() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        let name = "recording-\(UUID().uuidString).wav"
        let recording = app.store.root.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: recording)
        app.append(Message(role: "user", text: "Voice", audio: name), to: try XCTUnwrap(app.selectedID))
        let package = makeTemporaryFolder().appendingPathComponent("Backup.mochilibrary")
        let export = try XCTUnwrap(app.libraryController.exportBackup(to: package))
        try FileManager.default.removeItem(at: recording)
        try await export.value
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent(name)), Data([1, 2, 3]))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: app.store.root.path).contains {
                $0.hasPrefix(LibraryStore.exportStagingPrefix)
            })
    }
    @MainActor func testTemplateResultsNameTheirOwnLibraryTextFields() throws {
        let app = makeApp(root: makeTemporaryFolder())
        let list = try app.executeTemplateTool(.listConversationTemplates, arguments: [:])
        XCTAssertEqual(
            list["untrusted_fields"] as? [String],
            ["templates.title", "templates.description", "templates.character_name"])
        XCTAssertFalse((list["templates"] as? [[String: Any]] ?? []).isEmpty)
        let single = try app.executeTemplateTool(
            .getConversationTemplate, arguments: ["template_id": ConversationTemplate.builtins[0].id.uuidString])
        XCTAssertEqual(
            Set(single["untrusted_fields"] as? [String] ?? []),
            ["template.title", "template.description", "template.character_name", "template.instructions"])
    }
    @MainActor func testBlankModelFallsBackToTheDefault() {
        let defaults = makePreferences()
        let settings = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        settings.modelName = "  "
        XCTAssertEqual(settings.effectiveModelName, RealtimeService.defaultModel)
        XCTAssertEqual(settings.conversationService().model, RealtimeService.defaultModel)
        XCTAssertNil(defaults.object(forKey: "model"))
        settings.modelName = " custom-model "
        XCTAssertEqual(settings.practiceService().model, "custom-model")
        XCTAssertEqual(
            PreferencesStore(defaults, importLegacy: false, allowExternalControl: false).modelName, "custom-model")
    }
    @MainActor func testPracticeVoiceLabelFallsBackToTheDefaultVoice() {
        let settings = PreferencesStore(makePreferences(), importLegacy: false, allowExternalControl: false)
        settings.builtInPracticeVoice = "unknown"
        XCTAssertEqual(settings.practiceVoiceLabel, "\(RealtimeService.defaultVoice.capitalized) · Codex voice")
    }
}
