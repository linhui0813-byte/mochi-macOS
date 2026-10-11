import Darwin
import MochiTestSupport
import XCTest

@testable import MochiApp

final class AuditFixR2CTests: XCTestCase {
    func testDevelopmentPreferenceSuitesAreKeyedByTheWholePath() {
        let first = DevelopmentLaunch.preferencesSuite(forLibraryRoot: URL(fileURLWithPath: "/tmp/a/library"))
        let second = DevelopmentLaunch.preferencesSuite(forLibraryRoot: URL(fileURLWithPath: "/tmp/b/library"))
        XCTAssertNotEqual(first, second)
        // scripts/tests/single_instance_e2e.py derives this same name to delete the suite.
        XCTAssertEqual(first, "mochi-e2e-ffd31b389e0d359a930def429ce807e3")
        XCTAssertEqual(
            DevelopmentLaunch.preferencesSuite(forLibraryRoot: URL(fileURLWithPath: "/tmp/a/./library/")), first)
    }

    func testBundleMetadataIsTrustedOnlyWhenItPredatesTheProcess() throws {
        let folder = TestScratch.folder("instance")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Info.plist")
        let started = try XCTUnwrap(SingleInstanceController.startTime(getpid()))
        XCTAssertLessThanOrEqual(started.tv_sec, time(nil))
        try Data("x".utf8).write(to: file)
        // Written after this process started: an upgrade replaced it, so it does not describe the process.
        XCTAssertFalse(SingleInstanceController.unchangedSince(started, [file]))
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        XCTAssertTrue(SingleInstanceController.unchangedSince(now, [file]))
        XCTAssertFalse(SingleInstanceController.unchangedSince(now, [folder.appendingPathComponent("missing")]))
    }
}
