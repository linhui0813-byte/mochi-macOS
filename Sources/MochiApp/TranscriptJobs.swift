import Foundation

/// Transcriptions in flight, one per message: a retried transcription or the reply that carries a voice message.
/// A job's token proves it is still the current one, so a late result from a replaced job is ignored.
struct TranscriptJobs {
    private(set) var messageIDs: Set<UUID> = []
    private var tokens: [UUID:UUID] = [:]
    private var tasks: [UUID:Task<Void,Never>] = [:]
    var isIdle: Bool { tokens.isEmpty && tasks.isEmpty }
    func task(for messageID: UUID) -> Task<Void,Never>? { tasks[messageID] }
    func isCurrent(_ messageID: UUID, _ token: UUID) -> Bool { tokens[messageID] == token }
    /// Starts the job for a message, replacing any token it had.
    mutating func begin(_ messageID: UUID) -> UUID {
        let token = UUID(); tokens[messageID] = token; messageIDs.insert(messageID); return token
    }
    mutating func attach(_ task: Task<Void,Never>, to messageID: UUID) { tasks[messageID] = task }
    /// Ends the job only if `token` is still current.
    mutating func finish(_ messageID: UUID, _ token: UUID) {
        guard isCurrent(messageID,token) else { return }
        tokens.removeValue(forKey:messageID); messageIDs.remove(messageID); tasks.removeValue(forKey:messageID)
    }
    mutating func cancel(_ messageID: UUID) {
        tasks.removeValue(forKey:messageID)?.cancel()
        tokens.removeValue(forKey:messageID); messageIDs.remove(messageID)
    }
    mutating func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]; tokens = [:]; messageIDs = []
    }
}
