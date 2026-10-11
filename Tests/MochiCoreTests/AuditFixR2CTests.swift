import Darwin
import MochiTestSupport
import XCTest

@testable import MochiAutomation

final class AuditFixR2CTests: XCTestCase {
    private func ping(_ server: MochiMCPProtocol, id: String) throws -> [String: Any]? {
        let line = #"{"jsonrpc":"2.0","id":"# + id + #","method":"ping"}"#
        return try JSONSerialization.jsonObject(with: XCTUnwrap(server.respond(Data(line.utf8)))) as? [String: Any]
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

    /// Reading, handling and replying share one deadline from accept, so the reply lands inside the client's wait.
    @MainActor func testSlowRequestAndSlowHandlerStillReplyWithinTheServerBudget() async throws {
        let path = TestScratch.folder("socket").appendingPathComponent("control.sock").path
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        let server = LocalControlServer(timeout: 1)
        try server.start(path: path) { data in
            usleep(1_500_000)
            return data
        }
        defer { server.stop() }
        let (text, elapsed) = try await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = try LocalControl.address(path)
            let start = Date()
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            try LocalControl.configure(fd)
            usleep(200_000)  // A slow request used to restart the server's clock.
            try LocalControl.sendFrame(Data("hello".utf8), fd: fd)
            let reply = try LocalControl.receiveFrame(fd: fd, timeout: 3)
            return (String(decoding: reply, as: UTF8.self), Date().timeIntervalSince(start))
        }.value
        XCTAssertTrue(text.contains("may complete it"), text)
        XCTAssertLessThan(elapsed, 1, "The whole exchange must end within the server's one-second budget")
    }
}
