import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp

/// The parts split out of AppModel, tested without it.
final class ComponentTests: XCTestCase {
    // MARK: PreferencesStore

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

    // MARK: LibraryController

    @MainActor func testControllerOpensSavesAndDebouncesWithoutTheAppModel() async throws {
        let root = makeTemporaryFolder()
        let controller = LibraryController(root: root, demo: false)
        var reports: [String] = []
        controller.report = { reports.append($0) }
        var opened = false
        controller.open(managedIn: nil, isolated: true) { opened = true }
        XCTAssertTrue(opened)
        XCTAssertTrue(controller.readable)
        let chat = Conversation(title: "Saved")
        controller.selection = { chat.id }
        controller.library.conversations = [chat]
        XCTAssertTrue(controller.save())
        XCTAssertEqual(try LibraryStore(root: root).load().selectedConversationID, chat.id)
        controller.saveDelay = 20_000_000
        let revision = controller.revision
        for draft in ["H", "He", "Hel"] {
            controller.updateQuietly { $0.conversations[0].draft = draft }
            controller.scheduleSave()
        }
        XCTAssertEqual(controller.revision, revision)
        await waitUntil { !controller.hasPendingSave }
        XCTAssertEqual(try LibraryStore(root: root).load().conversations[0].draft, "Hel")
        XCTAssertTrue(reports.isEmpty)
    }
    @MainActor func testOnlyOneTransferRunsAndItIsClaimedImmediately() async throws {
        let root = makeTemporaryFolder()
        let controller = LibraryController(root: root, demo: false)
        controller.open(managedIn: nil, isolated: true) {}
        let package = makeTemporaryFolder().appendingPathComponent("Backup.mochilibrary")
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = try XCTUnwrap(controller.exportBackup(to: package))
        XCTAssertNotNil(controller.transfer)
        XCTAssertNil(controller.exportBackup(to: package.appendingPathExtension("second")))
        XCTAssertNil(controller.importBackup(from: package))
        try await first.value
        XCTAssertNil(controller.transfer)
    }
    @MainActor func testUnreadableLibraryRefusesCommits() throws {
        let root = makeTemporaryFolder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: root.appendingPathComponent("library.json"))
        let controller = LibraryController(root: root, demo: false)
        var reports: [String] = []
        controller.report = { reports.append($0) }
        controller.open(managedIn: nil, isolated: true) {}
        XCTAssertFalse(controller.readable)
        XCTAssertEqual(reports.count, 1)
        XCTAssertThrowsError(try controller.commit(Library()))
        XCTAssertFalse(controller.save())
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("library.json")), "damaged")
    }

    // MARK: Small types

    func testRecentResultsKeepsTheNewestEntries() {
        var results = RecentResults<Int>(limit: 3)
        for (index, key) in ["a", "b", "c", "a", "d"].enumerated() { results.insert(index, for: key) }
        XCTAssertEqual(results.count, 3)
        XCTAssertNil(results["a"])
        XCTAssertEqual(results["b"], 1)
        XCTAssertEqual(results["d"], 4)
        results.removeAll()
        XCTAssertTrue(results.isEmpty)
    }
    func testTranscriptJobsHonourOnlyTheCurrentToken() async {
        var jobs = TranscriptJobs()
        let id = UUID()
        let old = jobs.begin(id)
        let current = jobs.begin(id)
        XCTAssertFalse(jobs.isCurrent(id, old))
        XCTAssertTrue(jobs.isCurrent(id, current))
        jobs.finish(id, old)
        XCTAssertEqual(jobs.messageIDs, [id])
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        jobs.attach(task, to: id)
        XCTAssertNotNil(jobs.task(for: id))
        jobs.cancel(id)
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(jobs.isIdle)
        _ = jobs.begin(UUID())
        jobs.cancelAll()
        XCTAssertTrue(jobs.isIdle)
        XCTAssertTrue(jobs.messageIDs.isEmpty)
    }
}
