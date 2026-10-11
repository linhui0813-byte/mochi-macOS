import XCTest

@testable import MochiProviders

final class RealtimeEventsTests: XCTestCase {
    func testRestoredHistoryUsesRealtimeContentTypes() throws {
        for (role, expected) in [("assistant", "output_text"), ("user", "input_text"), ("system", "input_text")] {
            let event = RealtimeEvents.message(role: role, text: "Context")
            let item = try XCTUnwrap(event["item"] as? [String: Any])
            let content = try XCTUnwrap(item["content"] as? [[String: String]])
            XCTAssertEqual(item["role"] as? String, role)
            XCTAssertEqual(content.first?["type"], expected)
            XCTAssertEqual(content.first?["text"], "Context")
        }
    }
    func testRequestFormatErrorDoesNotBlameAccountOrEchoMessage() {
        var result = RealtimeAccumulator()
        XCTAssertThrowsError(
            try result.accept([
                "type": "error",
                "error": ["code": "invalid_value", "param": "item.content[0].type", "message": "private-token"],
            ])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("request format"))
            XCTAssertTrue(error.localizedDescription.contains("item.content[0].type"))
            XCTAssertFalse(error.localizedDescription.contains("account"))
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
        XCTAssertFalse(
            RealtimeEvents.failure(["code": "private-token", "param": "private-token"]).localizedDescription.contains(
                "private-token"))
        XCTAssertFalse(
            RealtimeEvents.failure(["code": "invalid_value", "param": "private-token"]).localizedDescription.contains(
                "private-token"))
    }
    func testRealtimeAccumulator() throws {
        var result = RealtimeAccumulator()
        try result.accept(["type": "response.output_text.delta", "delta": "Hello"])
        XCTAssertEqual(result.text, "Hello")
        try result.accept(["type": "response.output_audio.delta", "delta": Data([0, 1]).base64EncodedString()])
        XCTAssertEqual(result.audio.count, 2)
        XCTAssertThrowsError(try result.accept(["type": "error", "error": ["message": "private-token"]])) { error in
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
    }
    func testFailedResponseCannotBecomeSuccess() {
        var result = RealtimeAccumulator()
        XCTAssertThrowsError(try result.accept(["type": "response.done", "response": ["status": "failed"]]))
    }
}

extension RealtimeEventsTests {
    func testDamagedAudioDeltaIsRejected() {
        var reply = RealtimeAccumulator()
        XCTAssertThrowsError(try reply.accept(["type": "response.output_audio.delta", "delta": "not base64!"]))
        XCTAssertThrowsError(try reply.accept(["type": "response.output_audio.delta"]))
        XCTAssertTrue(reply.audio.isEmpty)
    }

    func testReplyStoppedAtTheLengthLimitIsKeptAndMarked() throws {
        var reply = RealtimeAccumulator()
        try reply.accept(["type": "response.output_text.delta", "delta": "A long answer"])
        try reply.accept([
            "type": "response.done",
            "response": ["status": "incomplete", "status_details": ["reason": "max_output_tokens"]],
        ])
        XCTAssertTrue(reply.done)
        XCTAssertTrue(reply.truncated)
        XCTAssertEqual(reply.text, "A long answer")
        var other = RealtimeAccumulator()
        XCTAssertThrowsError(
            try other.accept([
                "type": "response.done",
                "response": ["status": "incomplete", "status_details": ["reason": "content_filter"]],
            ]))
    }
}
