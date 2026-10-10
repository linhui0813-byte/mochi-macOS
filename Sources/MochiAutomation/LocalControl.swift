import Foundation
import Darwin
import CryptoKit
import MochiKernel

/// Why a frame could not be exchanged. Carried as the cause of the user-facing failure.
enum FrameError: Error { case ended, timedOut, oversized }
/// Private, same-user IPC. The MCP process is stdio; this socket is only its app bridge.
public enum LocalControl {
    public static let maxFrame = 262144
    /// How long the server waits for a request line, and for the app to start and finish handling it.
    public static let serverTimeout: TimeInterval = 5
    /// The client waits longer than the server's whole budget, so a reply is never lost to a race.
    public static let clientTimeout: TimeInterval = 8
    public static func path(forLibraryRoot root: URL) -> String {
        let digest = SHA256.hash(data:Data(root.standardizedFileURL.path.utf8)).prefix(12).map { String(format:"%02x",$0) }.joined()
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR,nil,0)
        var buffer = [CChar](repeating:0,count:max(count,1))
        let written = confstr(_CS_DARWIN_USER_TEMP_DIR,&buffer,buffer.count)
        // Use the OS-owned per-user directory, never an environment-selected global /tmp path.
        let root = written > 0 && written <= buffer.count ? URL(fileURLWithPath:String(cString:buffer)) : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return root.appendingPathComponent("mochi-control").appendingPathComponent("\(digest).sock").path
    }
    public static var defaultPath: String {
        path(forLibraryRoot:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(AppIdentity.name))
    }
    static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8) + [0]
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard bytes.count <= MemoryLayout.size(ofValue:address.sun_path) else { throw AppFailure("The local control socket path is too long.") }
        withUnsafeMutableBytes(of:&address.sun_path) { buffer in buffer.copyBytes(from:bytes) }
        return address
    }
    static func configure(_ fd: Int32) throws {
        let flags = fcntl(fd,F_GETFL)
        guard flags >= 0, fcntl(fd,F_SETFL,flags & ~O_NONBLOCK) == 0 else { throw AppFailure("Could not configure local control connection.") }
        var enabled: Int32 = 1
        guard setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&enabled,socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw AppFailure("Could not configure local control connection.") }
    }
    private static func waitReady(_ fd: Int32, event: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AppFailure("Local control connection timed out.",underlying:FrameError.timedOut) }
            var item = pollfd(fd:fd,events:event,revents:0)
            let status = poll(&item,1,Int32(min(remaining*1000+1,5000)))
            if (status < 0 && errno == EINTR) || status == 0 { continue } // A poll timeout re-checks the deadline.
            guard status > 0, item.revents & Int16(POLLNVAL) == 0 else { throw AppFailure("Local control connection ended or timed out.",underlying:FrameError.ended) }
            return
        }
    }
    static func sendFrame(_ data: Data, fd: Int32, timeout: TimeInterval = serverTimeout) throws {
        guard data.count <= maxFrame else { throw AppFailure("Control response exceeds the size limit.") }
        let frame = data + Data([10]), deadline = Date().addingTimeInterval(timeout)
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try waitReady(fd,event:Int16(POLLOUT),deadline:deadline)
                let count = Darwin.send(fd,buffer.baseAddress!.advanced(by:offset),min(4096,buffer.count-offset),MSG_DONTWAIT)
                if count < 0 && [EINTR,EAGAIN,EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { throw AppFailure("Local control connection ended.",underlying:FrameError.ended) }; offset += count
            }
        }
    }
    static func receiveFrame(fd: Int32, timeout: TimeInterval = serverTimeout) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating:0,count:4096)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try waitReady(fd,event:Int16(POLLIN),deadline:deadline)
            let count = recv(fd,&buffer,buffer.count,MSG_DONTWAIT)
            if count < 0 && [EINTR,EAGAIN,EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw AppFailure("Local control connection ended.",underlying:FrameError.ended) }
            if let newline = buffer.prefix(count).firstIndex(of:10) {
                data.append(contentsOf:buffer[..<newline]); guard data.count <= maxFrame else { throw AppFailure("Control request exceeds the size limit.",underlying:FrameError.oversized) }; return data
            }
            data.append(contentsOf:buffer.prefix(count))
            guard data.count <= maxFrame else { throw AppFailure("Control request exceeds the size limit.",underlying:FrameError.oversized) }
        }
    }
    public static func request(_ data: Data, path: String = defaultPath) throws -> Data {
        var info = stat()
        guard lstat(path,&info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o077 == 0 else { throw AppFailure("Open Mochi and enable external control in Settings → Automation.") }
        let fd = socket(AF_UNIX,SOCK_STREAM,0); guard fd >= 0 else { throw AppFailure("Could not open local control connection.") }
        defer { close(fd) }
        guard fcntl(fd,F_SETFL,O_NONBLOCK) == 0 else { throw AppFailure("Could not configure local control connection.") }
        var address = try address(path)
        let connected = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw AppFailure("Mochi is not listening. Enable external control in Settings → Automation.") }
            try waitReady(fd,event:Int16(POLLOUT),deadline:Date().addingTimeInterval(5))
            var failure: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd,SOL_SOCKET,SO_ERROR,&failure,&length) == 0, failure == 0 else { throw AppFailure("Mochi is not listening. Enable external control in Settings → Automation.") }
        }
        try configure(fd)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd,&uid,&gid) == 0, uid == getuid() else { throw AppFailure("Local control belongs to another user.") }
        try sendFrame(data,fd:fd); return try receiveFrame(fd:fd,timeout:clientTimeout)
    }
}
public final class LocalControlServer {
    private let lock = NSLock()
    private var active = false
    private var clients = Set<Int32>()
    private var generation = UUID()
    private var source: DispatchSourceRead?
    private var path: String?
    private var inode: ino_t = 0
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = LocalControl.serverTimeout) { self.timeout = timeout }
    /// Connections currently being served; at most eight.
    public var activeClientCount: Int { lock.lock(); defer { lock.unlock() }; return clients.count }
    public var endpointAvailable: Bool {
        guard let path else { return false }
        var info = stat()
        return lstat(path,&info) == 0 && info.st_ino == inode && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFSOCK && info.st_mode & 0o077 == 0
    }
    public func start(path: String, handler: @escaping @MainActor (Data) -> Data) throws {
        guard source == nil else { return }
        let directory = URL(fileURLWithPath:path).deletingLastPathComponent().path
        var info = stat()
        if lstat(directory,&info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else { throw AppFailure("Automation needs a real folder owned by your macOS user. Remove the conflicting path and enable control again.") }
            guard chmod(directory,0o700) == 0 else { throw AppFailure("Could not protect the automation folder. Check its permissions and enable control again.") }
        } else {
            try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
        if lstat(path,&info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw AppFailure("The automation path is already in use.") }
            let probe = socket(AF_UNIX,SOCK_STREAM,0); defer { close(probe) }
            guard probe >= 0, fcntl(probe,F_SETFL,O_NONBLOCK) == 0 else { throw AppFailure("Could not inspect the automation socket.") }
            var address = try LocalControl.address(path)
            let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(probe,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result != 0, errno == ECONNREFUSED else { throw AppFailure("Another Mochi instance owns external control.") }
            guard unlink(path) == 0 else { throw AppFailure("Could not clean up the inactive automation socket.") }
        }
        var address = try LocalControl.address(path)
        let fd = socket(AF_UNIX,SOCK_STREAM,0); guard fd >= 0 else { throw AppFailure("Could not create local control socket.") }
        let bound = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { close(fd); throw AppFailure("Could not bind local control socket.") }
        guard chmod(path,0o600) == 0, listen(fd,8) == 0 else { close(fd); unlink(path); throw AppFailure("Could not protect local control socket.") }
        guard fcntl(fd,F_SETFL,O_NONBLOCK) == 0 else { close(fd); unlink(path); throw AppFailure("Could not configure the control listener.") }
        _ = lstat(path,&info); inode = info.st_ino; self.path = path
        let generation = UUID()
        lock.lock(); active = true; self.generation = generation; lock.unlock()
        let source = DispatchSource.makeReadSource(fileDescriptor:fd,queue:DispatchQueue(label:"mochi.control.accept"))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let client = accept(fd,nil,nil); if client < 0 { break }
                self.lock.lock(); let allowed = self.active && self.clients.count < 8; if allowed { self.clients.insert(client) }; self.lock.unlock()
                guard allowed else { close(client); continue }
                let timeout = self.timeout
                DispatchQueue.global(qos:.utility).async { [weak self] in
                    guard let self else { close(client); return }
                    let activity = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.latencyCritical],reason:"Handle a local Mochi control request")
                    defer { ProcessInfo.processInfo.endActivity(activity); self.lock.lock(); self.clients.remove(client); self.lock.unlock(); close(client) }
                    func reply(_ message: String) {
                        if let data = try? JSONSerialization.data(withJSONObject:MochiTools.error(message)) { try? LocalControl.sendFrame(data,fd:client,timeout:timeout) }
                    }
                    do { try LocalControl.configure(client) } catch { MochiLog.failure(MochiLog.automation,"Configure control connection",error,level:.info); return }
                    var uid: uid_t = 0, gid: gid_t = 0
                    guard getpeereid(client,&uid,&gid) == 0, uid == getuid() else { MochiLog.automation.error("Refused a control connection from another macOS user"); return }
                    let data: Data
                    do { data = try LocalControl.receiveFrame(fd:client,timeout:timeout) }
                    catch {
                        MochiLog.failure(MochiLog.automation,"Read control request",error,level:.info)
                        // A client that left cannot read a reply; one that is slow or too large is told why.
                        if (error as? AppFailure)?.underlying as? FrameError != .ended { reply(AppFailure.message(for:error,fallback:"The control request could not be read.")) }
                        return
                    }
                    // The app must start within 80% of the budget; the rest is for finishing and replying.
                    let deadline = Date().addingTimeInterval(timeout * 0.8), complete = DispatchSemaphore(value:0)
                    let result = ControlReplyBox()
                    Task { @MainActor [weak self] in
                        guard let self else { complete.signal(); return }
                        if !self.isActive(generation) { result.finish(.inactive) }
                        else if Date() >= deadline { result.finish(.missedStart) }
                        else { result.start(); result.finish(.reply(handler(data))) }
                        complete.signal()
                    }
                    if complete.wait(timeout:.now() + timeout) == .timedOut {
                        MochiLog.automation.notice("A control request did not finish within its deadline")
                        reply(result.started ? "Mochi is still working on this request and may complete it. Read get_session before retrying." : "Mochi was busy and did not start this request. Retry in a moment.")
                        return
                    }
                    switch result.outcome {
                    case .reply(let response)?: try? LocalControl.sendFrame(response,fd:client,timeout:timeout)
                    case .inactive?: reply("Mochi stopped accepting external control. Enable it again in Settings → Automation.")
                    case .missedStart?, nil: reply("Mochi was busy and did not start this request. Retry in a moment.")
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }; self.source = source; source.resume()
    }
    private func isActive(_ expected: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return active && generation == expected }
    public func stop() {
        lock.lock(); active = false; generation = UUID(); for fd in clients { shutdown(fd,SHUT_RDWR) }; lock.unlock()
        source?.cancel(); source = nil
        if let path { var info = stat(); if lstat(path,&info) == 0 && info.st_ino == inode && info.st_uid == getuid() { unlink(path) } }
        path = nil
    }
    deinit { stop() }
}
/// Shared between the socket thread and the main actor: whether the handler started, and how it ended.
private final class ControlReplyBox {
    enum Outcome { case reply(Data), inactive, missedStart }
    private let lock = NSLock(); private var began = false, value: Outcome?
    func start() { lock.lock(); began = true; lock.unlock() }
    func finish(_ outcome: Outcome) { lock.lock(); value = outcome; lock.unlock() }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return began }
    var outcome: Outcome? { lock.lock(); defer { lock.unlock() }; return value }
}
