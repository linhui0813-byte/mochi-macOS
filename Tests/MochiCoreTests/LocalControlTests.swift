import Darwin
import MochiTestSupport
import XCTest

@testable import MochiAutomation

final class LocalControlTests: XCTestCase {
    /// Polls without blocking the main actor until `condition` holds or two seconds pass.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(condition())
    }
    /// Reads one reply line with plain recv, so the client's own size check is not involved.
    private nonisolated func readLine(_ fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { throw POSIXError(.ECONNRESET) }
            if let newline = buffer.prefix(count).firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    private func path() -> String { TestScratch.folder("socket").appendingPathComponent("control.sock").path }
    private func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try LocalControl.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        try LocalControl.configure(fd)
        return fd
    }
    @MainActor func testDelayedRequestAndLargeSlowResponse() async throws {
        let path = path()
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LocalControlServer()
        let response = Data(repeating: 65, count: 200000)
        try server.start(path: path) { _ in response }
        defer { server.stop() }
        let result = try await Task.detached { [self] in
            let fd = try connect(path)
            defer { close(fd) }
            // A deliberately slow client: the server must wait for the request instead of closing early.
            usleep(150_000)
            try LocalControl.sendFrame(Data("hello".utf8), fd: fd)
            return try readLine(fd)
        }.value
        XCTAssertEqual(result, response)
    }
    @MainActor func testShutdownRejectsPendingClientAndRemovesSocket() async throws {
        let path = path()
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let server = LocalControlServer()
        try server.start(path: path) { data in
            calls += 1
            return data
        }
        let client = try connect(path)
        defer { close(client) }
        try await eventually { server.activeClientCount == 1 }
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let result = await Task.detached { () -> Bool in
            do {
                try LocalControl.sendFrame(Data("late".utf8), fd: client)
                _ = try LocalControl.receiveFrame(fd: client)
                return true
            } catch { return false }
        }.value
        XCTAssertFalse(result)
        XCTAssertEqual(calls, 0)
    }
    @MainActor func testStaleSocketRecoveredAndOwnedFolderProtected() throws {
        let path = path()
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try LocalControl.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        XCTAssertEqual(bound, 0)
        let server = LocalControlServer()
        try server.start(path: path) { $0 }
        defer { server.stop() }
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o700)
    }
    func testStableShortEndpointForLongAndCustomRoots() {
        let root = URL(
            fileURLWithPath: "/Users/" + String(repeating: "long", count: 100) + "/Library/Application Support/Mochi")
        let path = LocalControl.path(forLibraryRoot: root)
        XCTAssertLessThan(path.utf8.count, 104)
        XCTAssertEqual(path, LocalControl.path(forLibraryRoot: root))
        XCTAssertNotEqual(path, LocalControl.path(forLibraryRoot: root.appendingPathComponent("other")))
    }
}
extension LocalControlTests {
    @MainActor func testServerRejectsOversizedRequestsItself() async throws {
        let path = path()
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let server = LocalControlServer()
        try server.start(path: path) { data in
            calls += 1
            return data
        }
        defer { server.stop() }
        // Raw sends bypass sendFrame's client-side check, so only the server's limit can stop this.
        let reply = try await Task.detached { [self] in
            let fd = try connect(path)
            defer { close(fd) }
            let huge = [UInt8](repeating: 65, count: LocalControl.maxFrame + 10) + [10]
            var offset = 0
            while offset < huge.count {
                let sent = huge[offset...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, min(65536, $0.count), 0) }
                if sent <= 0 { break }
                offset += sent
            }
            return try readLine(fd)
        }.value
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).contains("exceeds the size limit"))
        XCTAssertEqual(calls, 0)
        // The largest permitted request still reaches the handler.
        let largest = Data(repeating: 66, count: LocalControl.maxFrame)
        let echoed = try await Task.detached { try LocalControl.request(largest, path: path) }.value
        XCTAssertEqual(echoed, largest)
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testIdleClientIsDisconnectedAfterTheDeadline() async throws {
        let path = path()
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let server = LocalControlServer(timeout: 0.2)
        try server.start(path: path) { data in
            calls += 1
            return data
        }
        defer { server.stop() }
        let fd = try connect(path)
        defer { close(fd) }
        let start = Date()
        let reply = try await Task.detached { [self] in try readLine(fd) }.value
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(calls, 0)
        try await eventually { server.activeClientCount == 0 }
    }
    @MainActor func testBusyAppGetsAnAnswerInsteadOfASilentClose() async throws {
        let path = path()
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let server = LocalControlServer(timeout: 0.4)
        try server.start(path: path) { data in
            calls += 1
            return data
        }
        defer { server.stop() }
        let reply = Task.detached { try LocalControl.request(Data("hello".utf8), path: path) }
        usleep(700_000)  // Keep the main actor busy past the start deadline.
        let text = String(decoding: try await reply.value, as: UTF8.self)
        XCTAssertTrue(text.contains("busy and did not start"), text)
        XCTAssertEqual(calls, 0)
    }
    @MainActor func testSlowHandlerIsReportedAsPossiblyCompleting() async throws {
        let path = path()
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let server = LocalControlServer(timeout: 0.3)
        try server.start(path: path) { data in
            calls += 1
            usleep(600_000)
            return data
        }
        defer { server.stop() }
        let text = String(
            decoding: try await Task.detached { try LocalControl.request(Data("hello".utf8), path: path) }.value,
            as: UTF8.self)
        XCTAssertTrue(text.contains("may complete it"), text)
        XCTAssertEqual(calls, 1)
    }
    func testSymlinkFolderAndSocketAreRejected() throws {
        let root = TestScratch.folder("mochi-links")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let actual = root.appendingPathComponent("actual")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        XCTAssertThrowsError(try LocalControlServer().start(path: link.appendingPathComponent("c.sock").path) { $0 })
        let socketPath = actual.appendingPathComponent("c.sock")
        try FileManager.default.createSymbolicLink(
            at: socketPath, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try LocalControlServer().start(path: socketPath.path) { $0 })
        XCTAssertThrowsError(try LocalControl.request(Data(), path: socketPath.path))
    }
    @MainActor func testExcessConnectionsRejectedAndRecovered() async throws {
        let path = path()
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LocalControlServer()
        try server.start(path: path) { $0 }
        defer { server.stop() }
        var sockets: [Int32] = []
        defer { for socket in sockets { close(socket) } }
        for _ in 0..<8 { sockets.append(try connect(path)) }
        try await eventually { server.activeClientCount == 8 }
        // The server may close the ninth client before it is even configured; any failure to exchange is a rejection.
        let rejected = await Task.detached { [self] () -> Bool in
            do {
                let excess = try connect(path)
                defer { close(excess) }
                try LocalControl.sendFrame(Data("excess".utf8), fd: excess)
                _ = try LocalControl.receiveFrame(fd: excess)
                return false
            } catch { return true }
        }.value
        XCTAssertTrue(rejected)
        for socket in sockets { shutdown(socket, SHUT_RDWR) }
        try await eventually { server.activeClientCount == 0 }
        let reply = try await Task.detached { try LocalControl.request(Data("ready".utf8), path: path) }.value
        XCTAssertEqual(reply, Data("ready".utf8))
    }
}
extension LocalControlTests {
    func testEndpointUsesMacOSPrivateUserTemporaryDirectory() throws {
        let path = LocalControl.defaultPath
        XCTAssertFalse(path.hasPrefix("/tmp/"))
        XCTAssertFalse(path.hasPrefix("/private/tmp/"))
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
        var info = stat()
        XCTAssertEqual(lstat(parent.path, &info), 0)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(info.st_mode & 0o077, 0)
        XCTAssertLessThan(path.utf8.count, 104)
    }
}
