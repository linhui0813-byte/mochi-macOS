import AppKit
import Darwin
import XCTest

@testable import MochiApp

private final class RecordingDelegate: NSObject, NSWindowDelegate {}

final class AuditFixG4Tests: XCTestCase {
    @MainActor private func window() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
            defer: true)
    }

    @MainActor func testReplacedWindowGetsItsOwnDelegateBack() {
        let app = makeApp(demo: true)
        let tray = TrayController()
        let original = RecordingDelegate()
        let first = window()
        first.delegate = original
        tray.attach(first, model: app)
        XCTAssertTrue(first.delegate === tray)
        let second = window()
        tray.attach(second, model: app)
        XCTAssertTrue(first.delegate === original)
        XCTAssertTrue(second.delegate === tray)
        XCTAssertTrue(tray.window === second)
        // A window the tray no longer manages closes normally rather than being hidden on the new window's behalf.
        XCTAssertTrue(tray.windowShouldClose(first))
    }

    @MainActor func testFinishingWorkReportsAFailedSave() {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        defer { chmod(root.path, 0o700) }
        XCTAssertTrue(app.libraryReadable)
        XCTAssertTrue(TrayController.finishWork(app))
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        app.draft = "Unsaved words"
        XCTAssertFalse(TrayController.finishWork(app))
        XCTAssertNotNil(app.error)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertTrue(TrayController.finishWork(app))
    }
}
