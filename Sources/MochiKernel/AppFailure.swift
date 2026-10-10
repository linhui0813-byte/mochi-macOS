import Foundation

/// A failure whose message is safe to show the user. The underlying error is kept for diagnostics only.
public struct AppFailure: LocalizedError {
    public let message: String
    public let underlying: Error?
    public init(_ message: String, underlying: Error? = nil) {
        self.message = message
        self.underlying = underlying
    }
    public var errorDescription: String? { message }
    /// An `AppFailure` keeps its own words; any other error is shown as the caller's fallback.
    public static func message(for error: Error, fallback: String) -> String {
        (error as? AppFailure)?.message ?? fallback
    }
}
