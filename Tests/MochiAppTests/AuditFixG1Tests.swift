import MochiAutomation
import MochiCore
import MochiTestSupport
import XCTest

@testable import MochiApp

/// Resumes once, then refuses to play again.
private final class FailingResumePlayer: PlaybackPlayer {
    var duration: TimeInterval = 5
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    var starts = 0
    func play() -> Bool {
        starts += 1
        return starts == 1
    }
    func pause() {}
    func stop() {}
}

final class AuditFixG1Tests: XCTestCase {
    @MainActor private func app() -> AppModel {
        makeApp(root: TestScratch.folder("mochi-g1"), preferences: makePreferences())
    }

    @MainActor func testVoiceRetryOfScheduledActionIsNotRefused() throws {
        let app = app()
        defer {
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        let operation = UUID()
        let args: [String: Any] = ["conversation_id": id.uuidString, "english": "Let me think."]
        _ = app.turn.begin(.generating)
        let first = try app.executeVoiceTool("prepare_expression", arguments: args, operationID: operation)
        XCTAssertEqual(first["status"] as? String, "scheduled_after_reply")
        let retry = try app.executeVoiceTool("prepare_expression", arguments: args, operationID: operation)
        XCTAssertEqual(retry["status"] as? String, "scheduled_after_reply")
        XCTAssertThrowsError(
            try app.executeVoiceTool(
                "prepare_expression", arguments: ["conversation_id": id.uuidString, "english": "Something else"],
                operationID: operation))
        app.stop()
        XCTAssertNil(app.deferredToolAction)
        _ = app.turn.begin(.generating)
        let rescheduled = try app.executeVoiceTool("prepare_expression", arguments: args, operationID: operation)
        XCTAssertEqual(rescheduled["status"] as? String, "scheduled_after_reply")
        XCTAssertNotNil(app.deferredToolAction)
    }

    @MainActor func testLongMultibyteMessageIsShortenedNotDropped() throws {
        let app = app()
        defer {
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        let text = String(repeating: "我", count: 2000)
        app.append(Message(role: "user", text: text), to: id)
        let voice = try app.executeTool("get_messages", arguments: ["conversation_id": id.uuidString], origin: .voice)
        let messages = try XCTUnwrap(voice["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let shown = try XCTUnwrap(messages.first?["text"] as? String)
        XCTAssertFalse(shown.isEmpty)
        XCTAssertTrue(text.hasPrefix(shown))
        XCTAssertEqual(messages.first?["text_truncated"] as? Bool, true)
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: messages[0]).count, 6000)
        XCTAssertEqual(voice["has_more"] as? Bool, false)

        app.externalControlEnabled = true
        defer { app.externalControlEnabled = false }
        let external = try app.executeTool(
            "get_messages", arguments: ["conversation_id": id.uuidString], origin: .external)
        let whole = try XCTUnwrap((external["messages"] as? [[String: Any]])?.last)
        XCTAssertEqual(whole["text"] as? String, text)
        XCTAssertEqual(whole["text_truncated"] as? Bool, false)
    }

    @MainActor func testLongMultibyteExpressionIsShortenedNotDropped() throws {
        let app = app()
        defer {
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        let english = String(repeating: "我", count: 1000)
        let meaning = String(repeating: "意", count: 1000)
        app.library.expressions = [PracticeExpression(conversationID: id, meaning: meaning, english: english)]
        let result = try app.executeTool(
            "search_expressions", arguments: ["conversation_id": id.uuidString, "query": ""], origin: .voice)
        let expressions = try XCTUnwrap(result["expressions"] as? [[String: Any]])
        XCTAssertEqual(expressions.count, 1)
        XCTAssertEqual(expressions.first?["text_truncated"] as? Bool, true)
        XCTAssertTrue(english.hasPrefix(try XCTUnwrap(expressions.first?["english"] as? String)))
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: expressions[0]).count, 6000)
    }

    @MainActor func testResumeThatCannotRestartPlaybackFails() throws {
        let app = app()
        defer {
            app.externalControlEnabled = false
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        app.externalControlEnabled = true
        let player = FailingResumePlayer()
        app.audio.makePlayer = { _ in player }
        app.play("fixture.wav")
        _ = try app.executeTool(
            "pause_audio", arguments: ["conversation_id": id.uuidString, "expected_revision": app.controlRevision],
            origin: .external)
        XCTAssertTrue(app.audio.paused)
        XCTAssertThrowsError(
            try app.executeTool(
                "resume_audio",
                arguments: ["conversation_id": id.uuidString, "expected_revision": app.controlRevision],
                origin: .external))
        XCTAssertNil(app.playbackFile)
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
}
