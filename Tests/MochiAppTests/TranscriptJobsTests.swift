import XCTest

@testable import MochiApp

final class TranscriptJobsTests: XCTestCase {
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

    func testBeginningAReplacementTranscriptJobCancelsTheOldTask() {
        var jobs = TranscriptJobs()
        let id = UUID()
        _ = jobs.begin(id)
        let old = Task<Void, Never> { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        jobs.attach(old, to: id)
        _ = jobs.begin(id)
        XCTAssertTrue(old.isCancelled)
        XCTAssertNil(jobs.task(for: id))
        jobs.cancelAll()
    }

    @MainActor func testFinishedExclusiveJobReleasesItsTask() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.speech.textReply = { _, _ in "ready" }
        app.checkConnection()
        XCTAssertNotNil(app.currentTask)
        await waitUntil { !app.busy && app.currentTask == nil }
        XCTAssertEqual(app.serviceStatus, "Verified · text response received")
    }
}
