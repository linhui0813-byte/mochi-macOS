import MochiCore
import XCTest

@testable import MochiApp

final class ConversationSearchTests: XCTestCase {
    @MainActor func testSearchIsCurrentConversationOnlyAndIndependentOfSidebarFilter() {
        let app = makeApp(demo: true)
        app.resume()
        let first = Message(role: "user", text: "The café opens soon")
        let second = Message(role: "assistant", text: "Let's go to the CAFE")
        var unknown = Message(role: "user", text: "", audio: "voice.wav")
        unknown.transcriptionState = .failed
        let current = Conversation(title: "Unsearched title")
        let other = Conversation(title: "Other conversation")
        app.library.conversations = [current, other]
        app.select(current.id)
        app.append(first, to: current.id)
        app.append(second, to: current.id)
        app.append(unknown, to: current.id)
        app.append(Message(role: "user", text: "cafe"), to: other.id)
        app.history.query = "Other conversation"
        app.openConversationSearch()
        app.find.query = " CAFE "
        XCTAssertEqual(app.find.matchIDs, [first.id, second.id])
        XCTAssertEqual(app.history.query, "Other conversation")
        XCTAssertEqual(app.selectedID, current.id)
        app.find.query = "Unsearched title"
        XCTAssertTrue(app.find.matchIDs.isEmpty)
        app.find.query = "Voice recording"
        XCTAssertTrue(app.find.matchIDs.isEmpty)
        app.stop()
    }
    @MainActor func testMatchNavigationWrapsAndQueryChangesResetPosition() {
        let app = makeApp(demo: true)
        app.resume()
        let chat = Conversation()
        app.library.conversations = [chat]
        app.select(chat.id)
        let messages = [Message(role: "user", text: "one match"), Message(role: "assistant", text: "another match")]
        for message in messages { app.append(message, to: chat.id) }
        app.find.query = "match"
        XCTAssertEqual(app.find.matchID, messages[0].id)
        app.find.move(-1)
        XCTAssertEqual(app.find.matchID, messages[1].id)
        app.find.move(1)
        XCTAssertEqual(app.find.matchID, messages[0].id)
        app.find.move(1)
        app.find.query = "one"
        XCTAssertEqual(app.find.matchIndex, 0)
        XCTAssertEqual(app.find.matchID, messages[0].id)
        app.find.query = "missing"
        app.find.move(1)
        XCTAssertNil(app.find.matchID)
        XCTAssertEqual(app.find.matchIndex, 0)
        app.stop()
    }
    @MainActor func testSearchClosesOnConversationChangeOrExpressionsAndCanReopen() {
        let app = makeApp(demo: true)
        app.resume()
        let first = Conversation()
        let second = Conversation()
        app.library.conversations = [first, second]
        app.select(first.id)
        app.openConversationSearch()
        app.find.query = "hello"
        app.select(second.id)
        XCTAssertFalse(app.find.isOpen)
        XCTAssertEqual(app.find.query, "")
        app.openConversationSearch()
        app.find.query = "world"
        app.openExpressions()
        XCTAssertFalse(app.find.isOpen)
        XCTAssertEqual(app.find.query, "")
        app.openConversationSearch()
        XCTAssertFalse(app.find.isOpen)
        app.select(first.id)
        app.openConversationSearch()
        XCTAssertTrue(app.find.isOpen)
        app.find.close()
        XCTAssertFalse(app.find.isOpen)
        app.stop()
    }
}

extension ConversationSearchTests {
    @MainActor func testLateTranscriptKeepsSelectedMessageAndRemovalUsesNearestMatch() {
        let app = makeApp(demo: true)
        app.resume()
        let chat = Conversation()
        app.library.conversations = [chat]
        app.select(chat.id)
        let pending = Message(role: "user", text: "", audio: "pending.wav")
        let first = Message(role: "user", text: "match one")
        let selected = Message(role: "assistant", text: "match two")
        for message in [pending, first, selected] { app.append(message, to: chat.id) }
        app.find.query = "match"
        app.find.move(1)
        let ci = app.library.conversations.firstIndex { $0.id == chat.id }!
        app.library.conversations[ci].messages[0].text = "late match"
        XCTAssertEqual(app.find.matchID, selected.id)
        XCTAssertEqual(app.find.matchIndex, 2)
        app.library.conversations[ci].messages.removeLast()
        XCTAssertEqual(app.find.matchID, first.id)
        XCTAssertEqual(app.find.matchSet, Set([pending.id, first.id]))
        app.stop()
    }
    @MainActor func testManagerFindWithoutSelectionOrConversationView() {
        let app = makeApp(demo: true)
        app.resume()
        app.selectedID = nil
        app.showExpressions = true
        XCTAssertFalse(app.canFindInConversation)
        app.history.managerOpen = true
        XCTAssertTrue(app.canFindInConversation)
        let before = app.history.searchFocusRequest
        app.findInConversation()
        XCTAssertEqual(app.history.searchFocusRequest, before + 1)
        XCTAssertFalse(app.find.isOpen)
        app.history.renameID = UUID()
        XCTAssertFalse(app.canFindInConversation)
        app.stop()
    }
    @MainActor func testLargeConversationUsesCachedMatchesAcrossReadsAndUpdates() {
        let app = makeApp(demo: true)
        var chat = Conversation()
        chat.messages = (0..<1000).map { Message(role: "user", text: $0.isMultiple(of: 2) ? "match" : "other") }
        app.library.conversations = [chat]
        app.select(chat.id)
        app.find.query = "match"
        XCTAssertEqual(app.find.matchIDs.count, 500)
        for _ in 0..<1000 {
            XCTAssertEqual(app.find.matchSet.count, 500)
            XCTAssertEqual(app.find.matchID, chat.messages[0].id)
        }
        app.library.conversations[0].messages[1].text = "match"
        XCTAssertEqual(app.find.matchIDs.count, 501)
        app.stop()
    }
}
