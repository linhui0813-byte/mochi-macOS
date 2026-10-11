import MochiAutomation
import MochiTestSupport
import XCTest

@testable import MochiApp

final class AutomationControllerTests: XCTestCase {
    @MainActor func testProductionControlAndReplayCacheBound() async throws {
        let app = app()
        defer {
            app.externalControlEnabled = false
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        app.externalControlEnabled = true
        XCTAssertNotNil(app.automation.server)
        let request = try JSONSerialization.data(withJSONObject: [
            "name": "get_session", "arguments": [:], "request_id": "ipc",
        ])
        let path = app.controlSocketPath
        let result = try await Task.detached { try LocalControl.request(request, path: path) }.value
        XCTAssertEqual((try JSONSerialization.jsonObject(with: result) as! [String: Any])["ok"] as? Bool, true)
        for i in 0..<140 {
            _ = app.tools.handleControlRequest(
                try JSONSerialization.data(withJSONObject: [
                    "name": "get_session", "arguments": [:], "request_id": "r\(i)",
                ]))
        }
        XCTAssertEqual(app.automation.externalResults.count, 128)
        XCTAssertNil(app.automation.externalResults["r0"])
        app.externalControlEnabled = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    @MainActor func testLostSocketRebindsWithoutDroppingReplayCache() async throws {
        let app = app()
        defer {
            app.externalControlEnabled = false
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        app.externalControlEnabled = true
        let old = try XCTUnwrap(app.automation.server)
        let path = app.controlSocketPath
        let request = try JSONSerialization.data(withJSONObject: [
            "name": "get_session", "arguments": [:], "request_id": "retained",
        ])
        _ = app.tools.handleControlRequest(request)
        try FileManager.default.removeItem(atPath: path)
        XCTAssertFalse(old.endpointAvailable)
        app.configureAutomation()
        XCTAssertTrue(app.automation.server?.endpointAvailable == true)
        XCTAssertFalse(app.automation.server === old)
        XCTAssertNotNil(app.automation.externalResults["retained"])
        let reply = try await Task.detached { try LocalControl.request(request, path: path) }.value
        XCTAssertEqual((try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["ok"] as? Bool, true)
        app.externalControlEnabled = false
        XCTAssertNil(app.automation.healthTask)
    }

    @MainActor func testReconfigurationFollowsPathAndHandlerAndReleaseStopsPolling() async throws {
        let first = LocalControl.path(forLibraryRoot: TestScratch.folder("g1-control-a"))
        let second = LocalControl.path(forLibraryRoot: TestScratch.folder("g1-control-b"))
        var controller: AutomationController? = AutomationController()
        defer { controller?.configure(enabled: false, path: second, recheck: {}, handler: { _ in Data() }) }
        controller?.configure(enabled: true, path: first, recheck: {}, handler: { _ in Data(#"{"who":1}"#.utf8) })
        let original = try XCTUnwrap(controller?.server)
        XCTAssertTrue(original.endpointAvailable)
        controller?.configure(enabled: true, path: second, recheck: {}, handler: { _ in Data(#"{"who":2}"#.utf8) })
        XCTAssertFalse(original.endpointAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first))
        XCTAssertTrue(controller?.server?.endpointAvailable == true)
        let rebound = try XCTUnwrap(controller?.server)
        controller?.configure(enabled: true, path: second, recheck: {}, handler: { _ in Data(#"{"who":3}"#.utf8) })
        XCTAssertTrue(controller?.server === rebound)
        let request = Data(#"{"name":"get_session"}"#.utf8)
        let reply = try await Task.detached { try LocalControl.request(request, path: second) }.value
        XCTAssertEqual((try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["who"] as? Int, 3)

        let task = try XCTUnwrap(controller?.healthTask)
        controller = nil
        XCTAssertTrue(task.isCancelled)
    }

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

    @MainActor private func app() -> AppModel {
        makeApp(root: TestScratch.folder("mochi-automation"), preferences: makePreferences())
    }
}
