import Foundation
import MochiKernel

struct RealtimeTimeout: Error {}
/// Cancelling or expiring a deadline closes the transport to unblock a suspended receive.
/// Completion and expiry are arbitrated under one lock: whichever settles first wins, so a deadline
/// that fires after the operation finished never closes a transport that is still in use.
final class RealtimeDeadline: @unchecked Sendable {
    private enum Outcome { case running, finished, expired }
    private let lock = NSLock()
    private var outcome = Outcome.running
    /// True when this call expired the deadline; false when the operation had already finished.
    private func expire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running else { return false }
        outcome = .expired
        return true
    }
    /// True when the operation finished in time; false when the deadline had already expired.
    private func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running else { return outcome == .finished }
        outcome = .finished
        return true
    }
    static func run<T>(
        nanoseconds: UInt64, close: @escaping @Sendable () -> Void,
        operation: () async throws -> T
    ) async throws -> T {
        let state = RealtimeDeadline()
        let timer = Task {
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            guard !Task.isCancelled, state.expire() else { return }
            close()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler(
            operation: {
                do {
                    try Task.checkCancellation()
                    let result = try await operation()
                    guard state.finish() else { throw RealtimeTimeout() }
                    try Task.checkCancellation()
                    return result
                } catch {
                    let inTime = state.finish()
                    if Task.isCancelled { throw CancellationError() }
                    if !inTime { throw RealtimeTimeout() }
                    throw error
                }
            }, onCancel: close)
    }
}
/// The connection reported itself cancelled while the reply was not: it closed underneath.
struct RealtimeConnectionCancelled: Error {}
struct RealtimeChannel {
    let send: ([String: Any]) async throws -> Void
    let receive: () async throws -> [String: Any]
    let close: @Sendable () -> Void
    static func live(_ request: URLRequest) -> RealtimeChannel {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4_000_000
        socket.resume()
        return RealtimeChannel(
            send: { event in
                let bytes = try JSONSerialization.data(withJSONObject: event)
                try await surfacing { try await socket.send(.string(String(decoding: bytes, as: UTF8.self))) }
            },
            receive: {
                let message = try await surfacing { try await socket.receive() }
                let bytes: Data
                switch message {
                case .data(let data): bytes = data
                case .string(let text): bytes = Data(text.utf8)
                @unknown default: throw AppFailure("Unexpected Realtime response.")
                }
                guard let event = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw AppFailure("Invalid Realtime event.")
                }
                return event
            },
            close: {
                socket.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            })
    }
}
extension RealtimeChannel {
    /// A `CancellationError` from the connection is the reply's cancellation only when the reply was cancelled.
    /// Otherwise it is a failed connection, which must be reported instead of passing silently as the user's choice.
    static func surfacing<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() } catch is CancellationError where !Task.isCancelled {
            throw RealtimeConnectionCancelled()
        }
    }
}
