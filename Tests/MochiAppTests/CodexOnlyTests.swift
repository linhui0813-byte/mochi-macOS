import MochiCore
import XCTest

@testable import MochiApp

final class CodexOnlyTests: XCTestCase {
    @MainActor func testLegacyProviderPreferencesCannotSelectPaidProviders() throws {
        let suite = "mochi-codex-only-\(UUID())"
        let prefs = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: "/tmp/mochi-codex-only-\(UUID())")
        defer {
            prefs.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        prefs.set("api", forKey: "auth")
        prefs.set("personal", forKey: "practiceVoiceMode")
        prefs.set("old-clone", forKey: "clone")
        let legacyProfiles = Data("legacy profile bytes".utf8)
        prefs.set(legacyProfiles, forKey: "voiceProfiles")
        let app = makeApp(root: root, preferences: prefs)
        XCTAssertEqual(app.settings.builtInPracticeVoice, "marin")
        XCTAssertEqual(prefs.data(forKey: "voiceProfiles"), legacyProfiles)
        XCTAssertEqual(prefs.string(forKey: "clone"), "old-clone")
        XCTAssertFalse(app.busy)
        XCTAssertNil(app.error)
    }
    @MainActor func testRetiredElevenLabsSettingsAreIgnoredButRetainedWithSavedExamples() throws {
        let suite = "mochi-retired-elevenlabs-\(UUID())"
        let prefs = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: "/tmp/mochi-retired-elevenlabs-\(UUID())")
        defer {
            prefs.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let options = Data(
            #"{"voiceID":"custom123","voiceName":"Xiaolai","model":"eleven_multilingual_v2","speed":0.8}"#.utf8)
        prefs.set("elevenLabs", forKey: "practiceProvider")
        prefs.set(options, forKey: "elevenLabsOptions")
        let app = makeApp(root: root, preferences: prefs)
        XCTAssertEqual(app.settings.practiceVoiceLabel, "Marin · Codex voice")
        var item = PracticeExpression(conversationID: app.selectedID!, meaning: "", english: "Let me think.")
        item.reference = "elevenlabs-\(String(repeating:"a",count:64)).mp3"
        item.referenceKind = "Xiaolai · ElevenLabs"
        app.library.expressions = [item]
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(item.reference!))
        try app.store.save(app.library)
        let loaded = makeApp(root: root, preferences: prefs)
        XCTAssertEqual(loaded.library.expressions[0].reference, item.reference)
        XCTAssertEqual(loaded.library.expressions[0].referenceKind, "Xiaolai · ElevenLabs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(item.reference!).path))
        XCTAssertEqual(loaded.settings.practiceVoiceLabel, "Marin · Codex voice")
        XCTAssertEqual(prefs.string(forKey: "practiceProvider"), "elevenLabs")
        XCTAssertEqual(prefs.data(forKey: "elevenLabsOptions"), options)
    }
    @MainActor func testLegacyReferenceAudioAndLabelSurviveVoiceChangeAndRelaunch() throws {
        let suite = "mochi-retained-voice-\(UUID())"
        let prefs = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: "/tmp/mochi-retained-\(UUID())")
        defer {
            prefs.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let app = makeApp(root: root, preferences: prefs)
        var item = PracticeExpression(conversationID: app.selectedID!, meaning: "", english: "Hello")
        item.reference = "reference-old.mp3"
        item.referenceKind = "My Voice · Legacy"
        app.library.expressions = [item]
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(item.reference!))
        try app.store.save(app.library)
        app.settings.builtInPracticeVoice = "cedar"
        let loaded = makeApp(root: root, preferences: prefs)
        XCTAssertEqual(loaded.library.expressions[0].referenceKind, item.referenceKind)
        XCTAssertEqual(loaded.library.expressions[0].reference, item.reference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(item.reference!).path))
        XCTAssertEqual(loaded.settings.builtInPracticeVoice, "cedar")
    }
}
