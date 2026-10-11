import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore
@testable import MochiProviders

final class VoiceTests: XCTestCase {
    func testCatalogAndExactSentence() {
        XCTAssertEqual(RealtimeVoice.allCases.count, 10)
        XCTAssertTrue(ReferenceSpeech.matches("I'm ready to start.", "I’m ready to start!"))
        XCTAssertFalse(ReferenceSpeech.matches("I worked slowly.", "My progress was slow."))
        XCTAssertFalse(ReferenceSpeech.matches("one thing", "one thing. Let us begin."))
        XCTAssertFalse(ReferenceSpeech.matches("We'll start.", "Well start."))
    }
    func testReferenceCacheSeparatesModelAndVoice() {
        let a = ReferenceSpeech.cacheName(text: "Hello", model: "gpt-realtime", voice: "marin")
        XCTAssertNotEqual(a, ReferenceSpeech.cacheName(text: "Hello", model: "gpt-realtime", voice: "cedar"))
        XCTAssertNotEqual(a, ReferenceSpeech.cacheName(text: "Hello", model: "other-model", voice: "marin"))
        XCTAssertFalse(ReferenceSpeech.matches("   ", ""))
    }
}

extension VoiceTests {
    func testReferenceCacheSeparatesVoiceAndSpeed() {
        let a = ReferenceSpeech.cacheName(text: "Hello", model: "gpt-realtime", voice: "marin")
        let b = ReferenceSpeech.cacheName(text: "Hello", model: "gpt-realtime", voice: "cedar")
        XCTAssertNotEqual(a, b)
        var options = OpenAIVoiceOptions()
        options.speed = 0.8
        XCTAssertNotEqual(
            a, ReferenceSpeech.cacheName(text: "Hello", model: "gpt-realtime", voice: "marin", options: options))
    }

    func testCanonicallyEquivalentTextMatches() {
        XCTAssertTrue(ReferenceSpeech.matches("Un café, s'il vous plaît.", "Un cafe\u{0301}, s'il vous plai\u{0302}t!"))
        XCTAssertFalse(ReferenceSpeech.matches("café", "cafe"))
    }

    func testNonFiniteSpeedStillNamesTheCacheWithoutCrashing() {
        var nan = OpenAIVoiceOptions()
        nan.speed = .nan
        var infinite = OpenAIVoiceOptions()
        infinite.speed = .infinity
        let a = ReferenceSpeech.cacheName(text: "Hi", model: "m", voice: "marin", options: nan)
        let b = ReferenceSpeech.cacheName(text: "Hi", model: "m", voice: "marin", options: infinite)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, ReferenceSpeech.cacheName(text: "Hi", model: "m", voice: "marin"))
    }

    func testTruncatedReferenceAudioIsNotCached() async throws {
        let root = TestScratch.folder("g2-reference")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var result = RealtimeAccumulator()
        result.text = "Hello there."
        result.audio = Data(repeating: 1, count: 4800)
        result.truncated = true
        let cut = result
        do {
            _ = try await RealtimeService().referenceAudio(text: "Hello there.", root: root, force: true) { _ in cut }
            XCTFail("A truncated example was accepted")
        } catch {
            XCTAssertTrue(error is AppFailure)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCachedExampleIsReusedWithoutAReply() async throws {
        let root = TestScratch.folder("mochi-cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RealtimeService()
        let cached = root.appendingPathComponent(
            ReferenceSpeech.cacheName(text: "Hello.", model: service.model, voice: service.voice))
        try Data([1]).write(to: cached)
        let url = try await service.referenceAudio(text: "Hello.", root: root, force: false) { _ in
            XCTFail("A cached example must not be regenerated")
            throw AppFailure("no")
        }
        XCTAssertEqual(url, cached)
        var replied = false
        _ = try? await service.referenceAudio(text: "Hello.", root: root, force: true) { _ in
            replied = true
            throw AppFailure("offline")
        }
        XCTAssertTrue(replied)
    }

    func testUsingACachedExampleKeepsItFromCleanup() async throws {
        let root = try folder()
        let service = RealtimeService()
        let cached = root.appendingPathComponent(
            ReferenceSpeech.cacheName(text: "Hi.", model: service.model, voice: service.voice))
        try Data([1]).write(to: cached)
        try age(cached, days: 8)
        _ = try await service.referenceAudio(text: "Hi.", root: root, force: false) { _ in
            throw AppFailure("must not regenerate")
        }
        try LibraryStore(root: root).cleanupOrphanedAudio(Library())
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
    }

    private func write(_ text: String, to home: URL) throws {
        try Data(text.utf8).write(to: home.appendingPathComponent(".codex/auth.json"))
    }

    private func home() throws -> URL {
        let url = TestScratch.folder("mochi-home")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func folder() throws -> URL {
        let url = TestScratch.folder("mochi-files")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func age(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -days * 86400)], ofItemAtPath: url.path)
    }
}
