import MochiCore
import XCTest

@testable import MochiApp

final class VoiceModelTests: XCTestCase {
    @MainActor func testSelectingVoiceDoesNotRelabelSavedReference() {
        let app = makeApp(demo: true)
        app.startHelp()
        app.editEnglish("A sentence")
        app.ensureExpression()
        app.expression?.referenceKind = "Marin · Saved voice"
        app.settings.builtInPracticeVoice = "cedar"
        XCTAssertEqual(app.expression?.referenceKind, "Marin · Saved voice")
    }
    @MainActor func testVoiceOptionsPersistAndRejectInvalidPreferences() throws {
        let suite = "mochi-options-test-\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prefs = UserDefaults(suiteName: suite)!
        defer {
            prefs.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let app = makeApp(root: root, preferences: prefs)
        app.settings.conversationVoiceOptions.speed = 1.2
        app.settings.practiceVoiceOptions.speed = 0.8
        let loaded = makeApp(root: root, preferences: prefs)
        XCTAssertEqual(loaded.settings.conversationVoiceOptions.speed, 1.2)
        XCTAssertEqual(loaded.settings.practiceVoiceOptions.speed, 0.8)
        prefs.set(Data("{\"speed\":9}".utf8), forKey: "practiceVoiceOptions")
        XCTAssertEqual(makeApp(root: root, preferences: prefs).settings.practiceVoiceOptions.speed, 1)
    }
}
