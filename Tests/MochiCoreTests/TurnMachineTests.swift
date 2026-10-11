import XCTest

@testable import MochiCore

final class TurnMachineTests: XCTestCase {
    func testPauseInvalidatesGenerationAndKeepsMicLocal() {
        var turn = TurnMachine()
        let token = turn.begin(.generating)
        turn.pause()
        XCTAssertFalse(turn.finish(token))
        XCTAssertEqual(turn.mode, .practice)
        XCTAssertTrue(turn.startRecording())
        XCTAssertEqual(turn.owner, .practice)
        XCTAssertFalse(turn.startRecording())
        turn.resume()
        XCTAssertEqual(turn.owner, .none)
        XCTAssertEqual(turn.mode, .conversation)
    }

    func testPlaybackMustFinishBeforeRecording() {
        var turn = TurnMachine()
        let token = turn.begin(.playing)
        XCTAssertFalse(turn.startRecording())
        XCTAssertTrue(turn.finish(token))
        XCTAssertTrue(turn.startRecording())
        XCTAssertEqual(turn.owner, .conversation)
    }

    func testLatePermissionCannotFinishNewOperation() {
        var turn = TurnMachine()
        let permission = turn.begin(.requestingPermission)
        turn.pause()
        let generation = turn.begin(.generating)
        XCTAssertFalse(turn.finish(permission))
        XCTAssertEqual(turn.activity, .generating)
        XCTAssertTrue(turn.finish(generation))
        XCTAssertEqual(turn.owner, .none)
    }
}
