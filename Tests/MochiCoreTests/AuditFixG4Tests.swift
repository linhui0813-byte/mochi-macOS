import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiAutomation

final class AuditFixG4Tests: XCTestCase {
    private func respond(_ server: MochiMCPProtocol, _ request: [String: Any]) throws -> [String: Any]? {
        try server.respond(JSONSerialization.data(withJSONObject: request)).map {
            try JSONSerialization.jsonObject(with: $0) as! [String: Any]
        }
    }
    private func errorCode(_ reply: [String: Any]?) -> Int? {
        (reply?["error"] as? [String: Any])?["code"] as? Int
    }
    private func initialized() throws -> MochiMCPProtocol {
        let server = MochiMCPProtocol { _ in try JSONSerialization.data(withJSONObject: ["ok": true]) }
        _ = try respond(
            server,
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18", "capabilities": [:],
                    "clientInfo": ["name": "test", "version": "1"],
                ],
            ])
        return server
    }

    // MARK: MCP

    func testMalformedInitializedNotificationIsDiscardedWithoutChangingState() throws {
        let server = try initialized()
        XCTAssertNil(try respond(server, ["jsonrpc": "2.0", "method": "notifications/initialized", "params": [Int]()]))
        XCTAssertEqual(errorCode(try respond(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])), -32002)
        let valid: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized", "params": [String: Any]()]
        XCTAssertNil(try respond(server, valid))
        XCTAssertNil(errorCode(try respond(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/list"])))
    }
    func testInitializeRequiresClientNameAndVersion() throws {
        let server = MochiMCPProtocol()
        for client: [String: Any] in [[:], ["name": "test"], ["version": "1"], ["name": 1, "version": "1"]] {
            let reply = try respond(
                server,
                [
                    "jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": client],
                ])
            XCTAssertEqual(errorCode(reply), -32602, "\(client)")
        }
        let valid = try respond(
            server,
            [
                "jsonrpc": "2.0", "id": 2, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18", "capabilities": [:],
                    "clientInfo": ["name": "test", "version": "1"],
                ],
            ])
        XCTAssertNil(errorCode(valid))
    }
    func testJSONScalarsAreInvalidRequestsNotParseErrors() throws {
        let server = MochiMCPProtocol()
        for text in ["42", "\"text\"", "null", "true"] {
            let reply = try JSONSerialization.jsonObject(with: XCTUnwrap(server.respond(Data(text.utf8))))
            XCTAssertEqual(errorCode(reply as? [String: Any]), -32600, text)
        }
        let broken = try JSONSerialization.jsonObject(with: XCTUnwrap(server.respond(Data("{".utf8))))
        XCTAssertEqual(errorCode(broken as? [String: Any]), -32700)
    }
    func testRequestIDsMustBeStringsOrIntegers() throws {
        let server = MochiMCPProtocol()
        for id: Any in [1.5, -0.25] {
            let reply = try respond(server, ["jsonrpc": "2.0", "id": id, "method": "ping"])
            XCTAssertEqual(errorCode(reply), -32600)
            XCTAssertTrue(reply?["id"] is NSNull)
        }
        for id: Any in [7, 0, -3, "abc"] {
            let reply = try respond(server, ["jsonrpc": "2.0", "id": id, "method": "ping"])
            XCTAssertNil(errorCode(reply))
            XCTAssertNotNil(reply?["result"])
        }
    }

    // MARK: Tool validation

    func testSchemaLimitsAndRulesStillApplyAfterSplittingValidation() {
        XCTAssertThrowsError(
            try MochiTools.validate(
                name: "save_expression",
                arguments: [
                    "conversation_id": UUID().uuidString, "english": String(repeating: "a", count: 8001),
                ], origin: .voice))
        XCTAssertThrowsError(
            try MochiTools.validate(
                name: "save_expression", arguments: ["conversation_id": UUID().uuidString, "english": "  "],
                origin: .voice))
        XCTAssertNoThrow(
            try MochiTools.validate(
                name: "save_expression",
                arguments: ["conversation_id": UUID().uuidString, "english": String(repeating: "a", count: 8000)],
                origin: .voice))
        let advertised = MochiTools.catalog(origin: .external).first { $0.name == .saveExpression }
        XCTAssertEqual(advertised?.properties["english"]?["maxLength"] as? Int, MochiTools.maxInstructions)
        XCTAssertEqual(advertised?.properties["expected_revision"]?["maxLength"] as? Int, MochiTools.maxInstructions)
    }

    // MARK: Local control

    @MainActor func testOversizedHandlerReplyIsExplainedInsteadOfDroppingTheConnection() async throws {
        let root = TestScratch.folder("g4")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("c.sock").path
        let server = LocalControlServer()
        try server.start(path: path) { _ in Data(repeating: 65, count: LocalControl.maxFrame + 1) }
        defer { server.stop() }
        let reply = try await Task.detached { try LocalControl.request(Data("hi".utf8), path: path) }.value
        let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, false)
        XCTAssertTrue((object?["error"] as? String)?.contains("size limit") == true, String(describing: object))
    }
    @MainActor func testRestartOnTheSameEndpointReusesItsLockAndServes() async throws {
        let root = TestScratch.folder("g4")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("c.sock").path
        let first = LocalControlServer()
        try first.start(path: path) { $0 }
        XCTAssertThrowsError(try LocalControlServer().start(path: path) { $0 })
        XCTAssertTrue(first.endpointAvailable)
        first.stop()
        XCTAssertFalse(first.endpointAvailable)
        let second = LocalControlServer()
        try second.start(path: path) { _ in Data("second".utf8) }
        defer { second.stop() }
        XCTAssertTrue(second.endpointAvailable)
        let reply = try await Task.detached { try LocalControl.request(Data("hi".utf8), path: path) }.value
        XCTAssertEqual(reply, Data("second".utf8))
    }
}
