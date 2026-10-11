import MochiCore
import XCTest

@testable import MochiApp
@testable import MochiProviders

final class ConversationTurnTests: XCTestCase {
    @MainActor func testOpeningHelpOrExpressionsBeforeReplyExplicitlyCancelsForegroundRequest() async throws {
        for destination in 0..<3 {
            let app = makeApp(demo: true)
            app.resume()
            app.newChat()
            let gate = TestGate()
            let started = expectation(description: "Voice request started")
            app.speech.conversationReply = { _, _, callbacks in
                started.fulfill()
                await gate.wait()
                XCTAssertTrue(Task.isCancelled)
                try Task.checkCancellation()
                var result = RealtimeAccumulator()
                result.text = "Must not silently detach"
                result.done = true
                try callbacks.response(result)
            }
            app.requestReply(
                history: [], text: "", pcm: Data(repeating: 0, count: 4800), audioFile: "saved.wav",
                conversationID: app.selectedID!)
            let voiceID = try XCTUnwrap(app.conversation?.messages.first?.id)
            let job = try XCTUnwrap(app.transcripts.task(for: voiceID))
            await fulfillment(of: [started], timeout: 2)
            if destination == 0 {
                app.startHelp()
            } else if destination == 1 {
                app.openExpressions()
            } else {
                app.openExpression(
                    PracticeExpression(
                        conversationID: app.selectedID!, meaning: "Saved meaning", english: "Saved English"))
            }
            await gate.release()
            await job.value
            XCTAssertEqual(app.conversation?.messages.count, 1)
            XCTAssertEqual(app.conversation?.messages.first?.transcriptionState, .interrupted)
            XCTAssertTrue(app.transcripts.isIdle)
            XCTAssertTrue(app.notice?.contains("pending reply was cancelled") == true)
        }
    }

    @MainActor func testCancellationReturningNormallyStillSettlesVoiceStateAndExplainsTypedReply() async throws {
        for voice in [true, false] {
            let app = makeApp(demo: true)
            app.resume()
            app.newChat()
            let gate = TestGate()
            let started = expectation(description: "Request started")
            let returned = expectation(description: "Canceled stub returned normally")
            app.speech.conversationReply = { _, _, callbacks in
                started.fulfill()
                await gate.wait()
                XCTAssertTrue(Task.isCancelled)
                var result = RealtimeAccumulator()
                result.text = "Cancelled result"
                result.done = true
                try callbacks.response(result)
                returned.fulfill()
            }
            if voice {
                app.requestReply(
                    history: [], text: "", pcm: Data(repeating: 0, count: 4800), audioFile: "saved.wav",
                    conversationID: app.selectedID!)
            } else {
                app.draft = "Typed message"
                app.send()
            }
            let id = try XCTUnwrap(app.conversation?.messages.first?.id)
            let job = app.transcripts.task(for: id)
            await fulfillment(of: [started], timeout: 2)
            app.startHelp()
            await gate.release()
            await fulfillment(of: [returned], timeout: 2)
            if let job {
                await job.value
                XCTAssertEqual(app.conversation?.messages.first?.transcriptionState, .interrupted)
            }
            XCTAssertEqual(app.conversation?.messages.count, 1)
            XCTAssertTrue(app.notice?.contains("pending reply was cancelled") == true)
        }
    }
}
