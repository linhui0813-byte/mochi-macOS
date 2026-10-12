import MochiCore
import XCTest

@testable import MochiApp

@MainActor final class HistoryOrderTests: XCTestCase {
    func testTheChosenOrderIsRememberedAndUnknownOrdersFallBack() {
        let preferences = makePreferences()
        let settings = PreferencesStore(preferences, importLegacy: false, allowExternalControl: false)
        XCTAssertEqual(settings.historySort, .recent)
        settings.historySort = .companion
        XCTAssertEqual(
            PreferencesStore(preferences, importLegacy: false, allowExternalControl: false).historySort, .companion)
        preferences.set("by-mood", forKey: "historySort")
        XCTAssertEqual(
            PreferencesStore(preferences, importLegacy: false, allowExternalControl: false).historySort, .recent)
    }

    func testTheListFollowsTheOrderAndTheCharacterFilter() throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.newChat()
        let loki = try XCTUnwrap(app.selectedID)
        app.renameChat(loki, title: "Zebra")
        app.library.conversations[app.library.conversations.firstIndex { $0.id == loki }!].characterName = "Loki"
        app.newChat()
        let mochi = try XCTUnwrap(app.selectedID)
        app.renameChat(mochi, title: "Apple")
        app.settings.historySort = .title
        XCTAssertEqual(app.visibleChats.prefix(2).map(\.id), [mochi, loki])
        app.history.character = "Loki"
        XCTAssertEqual(app.visibleChats.map(\.id), [loki])
    }
}
