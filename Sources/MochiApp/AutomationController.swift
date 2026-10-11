import Foundation
import MochiAutomation
import MochiKernel

/// The most recent `limit` values by key, oldest dropped first.
struct RecentResults<Value> {
    let limit: Int
    private var values: [String: Value] = [:]
    private var order: [String] = []
    init(limit: Int = 128) { self.limit = limit }
    subscript(key: String) -> Value? { values[key] }
    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }
    mutating func insert(_ value: Value, for key: String) {
        if values[key] == nil { order.append(key) }
        values[key] = value
        if order.count > limit { values.removeValue(forKey: order.removeFirst()) }
    }
    mutating func removeAll() {
        values = [:]
        order = []
    }
}

/// The local control server and the result caches that make external and voice tool calls safe to retry.
@MainActor @Observable final class AutomationController {
    private(set) var status = "Disabled"
    @ObservationIgnored private(set) var server: LocalControlServer?
    @ObservationIgnored private(set) var healthTask: Task<Void, Never>?
    /// External replies by request ID: a retried request gets the first reply instead of running twice.
    @ObservationIgnored var externalResults = RecentResults<(signature: String, response: Data)>()
    /// Voice tool results by reply and arguments: a retried reply cannot repeat a side effect.
    @ObservationIgnored var voiceResults = RecentResults<[String: Any]>()
    /// The voice call currently executing, so an action it schedules can record its own result.
    @ObservationIgnored var voiceToolKey: String?
    /// The voice call whose action is scheduled after the reply, so a retry of it is not refused as a second one.
    @ObservationIgnored var scheduledVoiceToolKey: String?
    /// Template creations by client idempotency key, so a retry after a lost reply cannot duplicate one.
    @ObservationIgnored var templateCreations = RecentResults<(signature: String, template: [String: Any])>()

    /// The latest configuration's callbacks, read on each use so reconfiguring never leaves a stale one running.
    @ObservationIgnored private var recheck: (@MainActor () -> Void)?
    @ObservationIgnored private var handler: (@MainActor (Data) -> Data)?
    @ObservationIgnored private var serverPath: String?

    /// Starts, keeps alive or stops the server. `recheck` runs every 30 s while enabled, so a socket removed
    /// from the temporary folder is recreated; `handler` answers each request on the main actor.
    func configure(
        enabled: Bool, path: String, recheck: @escaping @MainActor () -> Void,
        handler: @escaping @MainActor (Data) -> Data
    ) {
        guard enabled else {
            healthTask?.cancel()
            healthTask = nil
            server?.stop()
            server = nil
            serverPath = nil
            self.recheck = nil
            self.handler = nil
            externalResults.removeAll()
            status = "Disabled"
            return
        }
        self.recheck = recheck
        self.handler = handler
        if healthTask == nil {
            healthTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    guard let self else { return }
                    self.recheck?()
                }
            }
        }
        if let server {
            if server.endpointAvailable && serverPath == path { return }
            server.stop()
            self.server = nil
            serverPath = nil
        }
        let server = LocalControlServer()
        do {
            try server.start(path: path) { [weak self] data in self?.handler?(data) ?? Data() }
            self.server = server
            serverPath = path
            status = "Available locally"
        } catch {
            MochiLog.failure(MochiLog.automation, "Start external control", error)
            status = AppFailure.message(for: error, fallback: "Could not start external control.")
        }
    }
    deinit { healthTask?.cancel() }
}
