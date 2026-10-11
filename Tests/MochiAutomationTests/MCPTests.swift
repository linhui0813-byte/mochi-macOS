import Darwin
import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiAutomation

final class MCPTests: XCTestCase {
    func response(_ server: MochiMCPProtocol, _ request: [String: Any]) throws -> [String: Any] {
        try JSONSerialization.jsonObject(
            with: XCTUnwrap(server.respond(JSONSerialization.data(withJSONObject: request)))) as! [String: Any]
    }
    func testLifecycleDiscoveryCallAndErrors() throws {
        var count = 0
        let server = MochiMCPProtocol { data in
            count += 1
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(payload["name"] as? String, "get_session")
            return try JSONSerialization.data(withJSONObject: ["ok": true, "revision": "current"])
        }
        XCTAssertNotNil(try response(server, ["jsonrpc": "2.0", "id": 0, "method": "tools/list"])["error"])
        let initialize = try response(
            server,
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18", "capabilities": [:],
                    "clientInfo": ["name": "test", "version": "1"],
                ],
            ])
        XCTAssertEqual((initialize["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(
            server.respond(
                try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])))
        let list = try response(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = (list["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.count, MochiTools.catalog(origin: .external).count)
        XCTAssertFalse(tools.contains { ($0["name"] as? String ?? "").contains("record") })
        let call = try response(
            server,
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "get_session", "arguments": [:]]])
        XCTAssertEqual((call["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(try response(server, ["jsonrpc": "2.0", "id": 4, "method": "server/discover"])["error"])
        XCTAssertNotNil(server.respond(Data("invalid".utf8)))
    }
    @MainActor func testRealSocketPermissionsRoundtripAndStop() async throws {
        let root = TestScratch.folder("mcp")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("control.sock").path
        let server = LocalControlServer()
        try server.start(path: path) { data in data }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let response = try await Task.detached { try LocalControl.request(Data("hello".utf8), path: path) }.value
        XCTAssertEqual(response, Data("hello".utf8))
        let another = LocalControlServer()
        XCTAssertThrowsError(try another.start(path: path) { $0 })
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try LocalControl.request(Data(), path: path))
    }
    func testUntrustedSocketPathRejected() throws {
        let root = TestScratch.folder("mcp")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("control.sock").path
        try Data().write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try LocalControl.request(Data("{}".utf8), path: path))
        XCTAssertThrowsError(try LocalControlServer().start(path: path) { $0 })
    }
}
extension MCPTests {
    func testInvalidIDsAndToolArgumentsAreProtocolErrors() throws {
        let server = MochiMCPProtocol { _ in
            XCTFail("Invalid request reached app")
            return Data()
        }
        for id: Any in [true, ["bad": "id"], String(repeating: "x", count: 201)] {
            let reply = try response(server, ["jsonrpc": "2.0", "id": id, "method": "ping"])
            XCTAssertTrue(reply["id"] is NSNull)
            XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32600)
        }
        _ = try response(
            server,
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1"],
                    "capabilities": [:],
                ],
            ])
        _ = server.respond(
            try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        for params: [String: Any] in [
            ["name": "unknown"], ["name": "get_messages", "arguments": ["conversation_id": "invalid"]],
        ] {
            let reply = try response(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": params])
            XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        let tools = MochiTools.catalog(origin: .external).map(\.mcp)
        for name in ["set_conversation_instructions", "set_conversation_preferences"] {
            XCTAssertEqual(
                (tools.first { $0["name"] as? String == name }?["annotations"] as? [String: Any])?["destructiveHint"]
                    as? Bool, true)
        }
        for name in ["list_conversations", "create_conversation", "open_conversation", "set_conversation_instructions"]
        {
            XCTAssertThrowsError(try MochiTools.validate(name: name, arguments: [:], origin: .voice))
        }
    }
}

extension MCPTests {
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

    func testRequestIDsMustBeIntegersOfAnySize() throws {
        let server = MochiMCPProtocol()
        for id in ["9007199254740992.5", "1.0", "1e3", "1.5", "99999999999999999999999.5", "true"] {
            let reply = try ping(server, id: id)
            XCTAssertEqual((reply?["error"] as? [String: Any])?["code"] as? Int, -32600, id)
            XCTAssertTrue(reply?["id"] is NSNull, id)
        }
        for id in [
            "9007199254740991", "-9007199254740991", "0", "42", "9007199254740992", "-9007199254740992",
            "18446744073709551615", "99999999999999999999999", "-9223372036854775809",
        ] {
            let reply = try ping(server, id: id)
            XCTAssertNotNil(reply?["result"], id)
            XCTAssertEqual((reply?["id"] as? NSNumber)?.stringValue, id)
        }
    }

    func testBridgeFailuresAreDiagnosedOnTheSideChannel() throws {
        var lines: [String] = []
        let server = MochiMCPProtocol(
            bridge: { _ in throw AppFailure("Open Mochi first.") }, diagnostics: { lines.append($0) })
        _ = server.respond(
            try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18", "capabilities": [:],
                    "clientInfo": ["name": "test", "version": "1"],
                ],
            ]))
        _ = server.respond(
            try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        let reply = try XCTUnwrap(
            server.respond(
                try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                    "params": ["name": "get_session", "arguments": [:]],
                ])))
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).contains("Open Mochi first."))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("get_session"))
    }

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

    private func ping(_ server: MochiMCPProtocol, id: String) throws -> [String: Any]? {
        let line = #"{"jsonrpc":"2.0","id":"# + id + #","method":"ping"}"#
        return try JSONSerialization.jsonObject(with: XCTUnwrap(server.respond(Data(line.utf8)))) as? [String: Any]
    }
}
