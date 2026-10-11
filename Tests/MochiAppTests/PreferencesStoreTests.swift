import Darwin
import MochiCore
import MochiTestSupport
import XCTest

@testable import MochiApp
@testable import MochiProviders

final class PreferencesStoreTests: XCTestCase {
    @MainActor func testPreferencesPersistAndInvalidValuesFallBack() {
        let defaults = makePreferences()
        let first = PreferencesStore(defaults, importLegacy: false, allowExternalControl: true)
        first.conversationVoice = "cedar"
        first.practiceVoiceOptions.speed = 0.8
        first.externalControlEnabled = true
        let second = PreferencesStore(defaults, importLegacy: false, allowExternalControl: true)
        XCTAssertEqual(second.conversationVoice, "cedar")
        XCTAssertEqual(second.practiceVoiceOptions.speed, 0.8)
        XCTAssertTrue(second.externalControlEnabled)
        defaults.set("unknown-voice", forKey: "conversationVoice")
        defaults.set(Data(#"{"speed":9}"#.utf8), forKey: "practiceVoiceOptions")
        let repaired = PreferencesStore(defaults, importLegacy: false, allowExternalControl: true)
        XCTAssertEqual(repaired.conversationVoice, RealtimeService.defaultVoice)
        XCTAssertEqual(repaired.practiceVoiceOptions, OpenAIVoiceOptions())
        XCTAssertFalse(
            PreferencesStore(defaults, importLegacy: false, allowExternalControl: false).externalControlEnabled)
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

    @MainActor func testGreetingHistoryKeepsTheLastThreeAndServicesUseTheChosenVoices() {
        let store = PreferencesStore(makePreferences(), importLegacy: false, allowExternalControl: false)
        store.recentGreetings = ["a", "b", "c", "d"]
        XCTAssertEqual(store.recentGreetings, ["b", "c", "d"])
        store.conversationVoice = "ash"
        store.builtInPracticeVoice = "sage"
        XCTAssertEqual(store.conversationService(speed: 0.7).voice, "ash")
        XCTAssertEqual(store.conversationService(speed: 0.7).options.speed, 0.7)
        XCTAssertEqual(store.practiceService().voice, "sage")
        XCTAssertEqual(store.practiceService(voice: "verse").voice, "verse")
    }

    @MainActor func testLegacyProviderPreferencesCannotSelectPaidProviders() throws {
        let suite = "mochi-codex-only-\(UUID())"
        let prefs = TestScratch.preferences(named: suite)
        let root = TestScratch.folder("mochi-codex-only")
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
        let prefs = TestScratch.preferences(named: suite)
        let root = TestScratch.folder("mochi-retired-elevenlabs")
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
        let prefs = TestScratch.preferences(named: suite)
        let root = TestScratch.folder("mochi-retained")
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

    func testDevelopmentPreferenceSuitesAreKeyedByTheWholePath() {
        let first = DevelopmentLaunch.preferencesSuite(forLibraryRoot: URL(fileURLWithPath: "/tmp/a/library"))
        let second = DevelopmentLaunch.preferencesSuite(forLibraryRoot: URL(fileURLWithPath: "/tmp/b/library"))
        XCTAssertNotEqual(first, second)
        // scripts/tests/single_instance_e2e.py derives this same name to delete the suite.
        XCTAssertEqual(first, "mochi-e2e-ffd31b389e0d359a930def429ce807e3")
        XCTAssertEqual(
            DevelopmentLaunch.preferencesSuite(forLibraryRoot: URL(fileURLWithPath: "/tmp/a/./library/")), first)
    }
}
