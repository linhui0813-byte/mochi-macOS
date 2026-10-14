import Foundation

/// Reuses only an idle connection belonging to the same local conversation, model and voice.
/// Only an idle health check can reconnect automatically; a submitted turn is never resent.
@MainActor public final class RealtimeConversationConnection {
    private var cached: ConversationConnectionState?
    private var active: [UUID: ConversationConnectionState] = [:]
    private var idleTask: Task<Void, Never>?
    private let credential: (RealtimeService) async throws -> String
    private let connect: (URLRequest) -> RealtimeChannel
    private let now: () -> Date
    private let idleNanoseconds: UInt64

    public convenience init() {
        self.init(credential: { try await $0.token() }, connect: RealtimeChannel.live)
    }
    init(
        credential: @escaping (RealtimeService) async throws -> String,
        connect: @escaping (URLRequest) -> RealtimeChannel, now: @escaping () -> Date = Date.init,
        idleNanoseconds: UInt64 = 120_000_000_000
    ) {
        self.credential = credential
        self.connect = connect
        self.now = now
        self.idleNanoseconds = idleNanoseconds
    }
    /// Close immediately on Stop, a conversation change, or switching off continuous conversation.
    public func reset() {
        idleTask?.cancel()
        idleTask = nil
        cached?.close()
        cached = nil
        for state in active.values { state.close() }
        active.removeAll()
    }
    public func reply(
        service: RealtimeService, input: ConversationRequest,
        onResponse: (@MainActor (RealtimeAccumulator) throws -> Void)? = nil,
        onTranscription: (@MainActor (RealtimeAccumulator) -> Void)? = nil,
        onTool: (@MainActor (String, [String: Any], String) throws -> [String: Any])? = nil,
        onAudio: (@MainActor (Data) -> Void)? = nil
    ) async throws -> RealtimeAccumulator {
        if !service.reuseConnection, input.conversationID != nil { reset() }
        guard service.reuseConnection, let conversationID = input.conversationID, !input.help, !input.reference else {
            return try await service.reply(
                input, credential: { try await self.credential(service) }, connect: connect,
                onResponse: onResponse, onTranscription: onTranscription, onTool: onTool, onAudio: onAudio)
        }
        idleTask?.cancel()
        idleTask = nil
        let key = "\(conversationID)|\(service.model)|\(service.voice)|\(onTool != nil)"
        var state: ConversationConnectionState
        if let old = cached, old.key == key, !old.busy, !old.closed,
            now().timeIntervalSince(old.created) < 55 * 60
        {
            state = old
        } else {
            // A previous turn may still be finishing its transcript. Give this turn its own socket rather
            // than racing two receivers or interrupting the earlier transcript.
            if let old = cached, !old.busy { old.close() }
            state = ConversationConnectionState(key: key, created: now())
            cached = state
        }
        state.busy = true
        active[state.id] = state
        var existing = state.channel
        input.voiceTiming?.record(existing == nil ? .connectionNew : .connectionReused)
        do {
            if let channel = existing {
                do {
                    try await RealtimeDeadline.run(nanoseconds: 3_000_000_000, close: channel.close) {
                        try await channel.ping()
                    }
                } catch {
                    state.close()
                    state.busy = false
                    active[state.id] = nil
                    // This check sends no conversation data. Reconnect safely before submitting the turn.
                    try Task.checkCancellation()
                    guard cached === state else { throw CancellationError() }
                    state = ConversationConnectionState(key: key, created: now())
                    cached = state
                    state.busy = true
                    active[state.id] = state
                    existing = nil
                }
                try Task.checkCancellation()
                guard cached === state, !state.closed else { throw CancellationError() }
                input.voiceTiming?.record(.pingReady)
            }
            let result = try await service.reply(
                input, credential: { try await self.credential(service) },
                connect: { state.install(self.connect($0)) }, onResponse: onResponse,
                onTranscription: onTranscription, onTool: onTool, onAudio: onAudio,
                existingChannel: existing, previousItemIDs: state.itemIDs, retainingConnection: true)
            state.busy = false
            active[state.id] = nil
            if cached === state, !state.closed {
                let delay = idleNanoseconds
                idleTask = Task { [weak self, weak state] in
                    do { try await Task.sleep(nanoseconds: delay) } catch { return }
                    guard let self, let state, self.cached === state, !state.busy else { return }
                    state.close()
                    self.cached = nil
                    self.idleTask = nil
                }
            } else {
                state.close()
                if cached === state { cached = nil }
            }
            return result
        } catch {
            state.busy = false
            state.close()
            active[state.id] = nil
            if cached === state { cached = nil }
            throw error
        }
    }
}

/// A receive can run outside the main actor. Its small item ledger and closing are protected together.
private final class ConversationConnectionState: @unchecked Sendable {
    let id = UUID()
    let key: String
    let created: Date
    var busy = false  // Owned by RealtimeConversationConnection's main actor.
    private let lock = NSLock()
    private var raw: RealtimeChannel?
    private var items = Set<String>()
    private var isClosed = false
    init(key: String, created: Date) {
        self.key = key
        self.created = created
    }
    var closed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }
    var itemIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items.sorted()
    }
    var channel: RealtimeChannel? {
        lock.lock()
        let raw = self.raw
        lock.unlock()
        return raw.map(tracking)
    }
    func install(_ raw: RealtimeChannel) -> RealtimeChannel {
        lock.lock()
        self.raw = raw
        let closed = isClosed
        lock.unlock()
        if closed { raw.close() }
        return tracking(raw)
    }
    private func tracking(_ raw: RealtimeChannel) -> RealtimeChannel {
        RealtimeChannel(
            send: raw.send,
            receive: {
                let event = try await raw.receive()
                self.record(event)
                return event
            }, close: { self.close() }, ping: raw.ping)
    }
    private func record(_ event: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        switch event["type"] as? String {
        case "conversation.item.added", "conversation.item.created", "response.output_item.added":
            if let id = (event["item"] as? [String: Any])?["id"] as? String { items.insert(id) }
        case "input_audio_buffer.committed":
            if let id = event["item_id"] as? String { items.insert(id) }
        case "response.done":
            let output = (event["response"] as? [String: Any])?["output"] as? [[String: Any]] ?? []
            for item in output { if let id = item["id"] as? String { items.insert(id) } }
        case "conversation.item.deleted":
            if let id = event["item_id"] as? String { items.remove(id) }
        default: break
        }
    }
    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let raw = self.raw
        lock.unlock()
        raw?.close()
    }
    deinit { raw?.close() }
}
