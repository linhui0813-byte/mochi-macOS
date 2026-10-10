import XCTest
@testable import MochiApp

final class NoticeTests: XCTestCase {
    @MainActor func testConversationNoticeDismissesAfterFourSeconds() async {
        let app = makeApp(demo:true); app.resume(); app.notice = nil
        let gate = TestGate(); var scheduled = false
        app.noticeSleep = { duration in XCTAssertEqual(duration,4_000_000_000); scheduled = true; await gate.wait() }
        app.notice = "Help draft saved."
        await waitUntil { scheduled }
        XCTAssertNotNil(app.notice)
        await gate.release(); await waitUntil { app.notice == nil }
        app.stop()
    }
    @MainActor func testReplacingEvenIdenticalNoticeRejectsOldExpiry() async {
        let app = makeApp(demo:true); app.resume(); app.notice = nil
        let first = TestGate(), second = TestGate(); var scheduled = 0
        app.noticeSleep = { _ in scheduled += 1; await first.wait() }
        app.notice = "Saved."
        await waitUntil { scheduled == 1 }
        let firstExpiry = try? XCTUnwrap(app.pendingNoticeDismissal)
        app.noticeSleep = { _ in scheduled += 1; await second.wait() }
        app.notice = "Saved."
        await waitUntil { scheduled == 2 }
        await first.release(); await firstExpiry?.value
        XCTAssertEqual(app.notice,"Saved.")
        await second.release(); await waitUntil { app.notice == nil }
        app.stop()
    }
    @MainActor func testManualDismissAndNavigationRejectLateExpiry() async {
        let app = makeApp(demo:true); app.resume(); app.notice = nil
        for navigate in [false,true] {
            let gate = TestGate(); var scheduled = false
            app.noticeSleep = { _ in scheduled = true; await gate.wait() }
            app.notice = "Saved."
            await waitUntil { scheduled }
            let expiry = app.pendingNoticeDismissal
            XCTAssertNotNil(expiry)
            if navigate { app.select(app.library.conversations.last!.id) } else { app.notice = nil }
            XCTAssertNil(app.notice)
            await gate.release(); await expiry?.value
            XCTAssertNil(app.notice)
        }
        app.stop()
    }
    @MainActor func testHelpGuidanceAndErrorsDoNotAutoDismiss() async {
        let app = makeApp(demo:true); app.notice = nil
        XCTAssertTrue(app.practice)
        var scheduled = false
        app.noticeSleep = { _ in scheduled = true }
        app.notice = "Check the recognized thought before finding the English."
        app.error = "Connection failed."
        XCTAssertNil(app.pendingNoticeDismissal)
        XCTAssertFalse(scheduled); XCTAssertNotNil(app.notice); XCTAssertNotNil(app.error)
        app.stop()
    }
}
