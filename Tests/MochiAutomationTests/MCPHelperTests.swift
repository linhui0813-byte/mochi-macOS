import MochiAutomation
import XCTest

final class MCPHelperTests: XCTestCase {
    func testFramerAcceptsTheLimitAndRecoversAfterAnOversizedLine() {
        var framer = MCPStdioFramer(limit: 8)
        XCTAssertEqual(framer.feed(Data("12345678\n".utf8)), [.request(Data("12345678".utf8))])
        XCTAssertEqual(framer.feed(Data("123456789".utf8)), [])
        XCTAssertEqual(framer.feed(Data("more\nok\n".utf8)), [.oversized, .request(Data("ok".utf8))])
        XCTAssertEqual(framer.feed(Data("\n".utf8)), [.request(Data())])
        XCTAssertEqual(framer.feed(Data("par".utf8)), [])
        XCTAssertEqual(framer.feed(Data("tial\nlast".utf8)), [.request(Data("partial".utf8))])
        XCTAssertEqual(framer.finish(), .request(Data("last".utf8)))
        XCTAssertNil(framer.finish())
        _ = framer.feed(Data(repeating: 65, count: 9))
        XCTAssertEqual(framer.finish(), .oversized)
    }

    func testHelperAnswersAnInteractiveClientWithoutWaitingForEndOfInput() throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mochi-mcp")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: helper.path), "Build the mochi-mcp product before testing")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        process.environment = ["MOCHI_CONTROL_SOCKET": "/nonexistent/mochi.sock"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let request =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
        input.fileHandleForWriting.write(Data((request + "\n").utf8))
        // Stdin stays open: a helper that waits for more input never answers.
        let answered = expectation(description: "Helper answered")
        var line = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            line.append(handle.availableData)
            if line.contains(10) {
                handle.readabilityHandler = nil
                answered.fulfill()
            }
        }
        wait(for: [answered], timeout: 5)
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.prefix { $0 != 10 }) as? [String: Any])
        XCTAssertEqual((reply["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertTrue(
            ((reply["result"] as? [String: Any])?["instructions"] as? String)?.contains("untrusted_fields") == true)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
