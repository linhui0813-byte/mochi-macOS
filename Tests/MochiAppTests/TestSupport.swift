import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp

extension SpeechServices {
    /// Fails the test on any network call it did not fake.
    static var unexpected: SpeechServices {
        func refuse(_ what: String) -> AppFailure {
            XCTFail("Unexpected \(what): set app.speech in this test")
            return AppFailure("No speech service in this test.")
        }
        return SpeechServices(
            conversationReply: { _, _, _ in throw refuse("conversation reply") },
            textReply: { _, _ in throw refuse("text reply") },
            referenceAudio: { _, _, _, _ in throw refuse("reference audio") },
            transcribe: { _, _ in throw refuse("transcription") })
    }
}
extension MediaServices {
    /// Stopping and metering are harmless. Asking for the microphone or recording fails the test.
    static var silent: MediaServices {
        MediaServices(
            permission: {
                XCTFail("Unexpected microphone permission request: set app.media.permission")
                return false
            },
            record: { _ in
                XCTFail("Unexpected recording: set app.media.record")
                throw AppFailure("No microphone in this test.")
            },
            stopRecording: { nil },
            meter: { -80 })
    }
}
/// A player that starts at once and finishes only when the test says so.
final class TestPlayer: PlaybackPlayer {
    var duration: TimeInterval = 5
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    var playing = false
    func play() -> Bool {
        playing = true
        return true
    }
    func pause() { playing = false }
    func stop() { playing = false }
}

extension XCTestCase {
    /// Preferences private to this test, removed when it ends.
    func makePreferences(named suite: String = "mochi-test-\(UUID().uuidString)") -> UserDefaults {
        let preferences = UserDefaults(suiteName: suite)!
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        return preferences
    }
    /// A temporary folder removed when the test ends.
    func makeTemporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mochi-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    /// An AppModel with private preferences and fake services; playing audio fails the test unless it sets a player.
    /// Demo models get their own temporary folder.
    /// Pass `applicationSupport` without `root` to exercise the managed data folder and its migration.
    @MainActor func makeApp(
        demo: Bool = false, root: URL? = nil, preferences: UserDefaults? = nil,
        speech: SpeechServices = .unexpected, media: MediaServices = .silent, applicationSupport: URL? = nil
    ) -> AppModel {
        precondition(root != nil || demo || applicationSupport != nil, "A test must never open the real data folder.")
        let app = AppModel(
            demo: demo, libraryRoot: root ?? (demo ? makeTemporaryFolder() : nil),
            preferences: preferences ?? makePreferences(),
            speech: speech, media: media, applicationSupport: applicationSupport)
        app.audio.makePlayer = { _ in
            XCTFail("Unexpected playback: set app.audio.makePlayer")
            throw AppFailure("No speaker in this test.")
        }
        app.chooseFile = { request in
            XCTFail("Unexpected file panel \(request): call the URL-taking method")
            return nil
        }
        return app
    }
    /// Polls on the main actor until `condition` holds or the timeout passes, then asserts it.
    @MainActor func waitUntil(
        timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "Condition not met within \(timeout) s", file: file, line: line)
    }
    func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "Fixtures"
        ).appendingPathComponent(name)
    }
}
