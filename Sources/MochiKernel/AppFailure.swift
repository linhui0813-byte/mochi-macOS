import Foundation

/// A failure whose message is safe to show the user. The underlying error is kept for diagnostics only.
public struct AppFailure: LocalizedError {
    public let message: String
    public let underlying: Error?
    /// Translates the message into the app's language; a literal here becomes a key in the string catalog.
    public init(_ message: String.LocalizationValue, underlying: Error? = nil) {
        self.init(verbatim: String(localized: message), underlying: underlying)
    }
    /// Keeps text that is already final: words from a server, or a message translated elsewhere.
    public init(verbatim message: String, underlying: Error? = nil) {
        self.message = message
        self.underlying = underlying
    }
    public var errorDescription: String? { message }
    /// An `AppFailure` keeps its own words; any other error is shown as the caller's fallback.
    public static func message(for error: Error, fallback: String.LocalizationValue) -> String {
        (error as? AppFailure)?.message ?? String(localized: fallback)
    }
}
