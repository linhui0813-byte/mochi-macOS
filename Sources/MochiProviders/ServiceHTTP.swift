import Foundation
import MochiKernel

public enum ServiceHTTP {
    /// Only session credentials travel over plain HTTPS; anything larger is a fault.
    static let maximumResponse = 1_000_000
    public static func failure(status: Int, provider: String) -> AppFailure {
        switch status {
        case 300..<400:
            return AppFailure(
                "\(provider) redirected the request, which Mochi refuses for your security. A proxy or captive portal may be interfering."
            )
        case 401:
            return AppFailure(
                provider == "OpenAI"
                    ? "Your Codex sign-in was rejected. Sign in through Codex again, then retry."
                    : "\(provider) credentials were rejected. Update them in Settings.")
        case 403: return AppFailure("This account does not have access to \(provider).")
        case 429: return AppFailure("\(provider) usage limit reached. Retry later.")
        default: return AppFailure("\(provider) request failed (HTTP \(status)). Check Settings and retry.")
        }
    }
    /// A user-facing message for a transport failure that tells apart being offline, a timeout and an intercepted connection.
    public static func transportFailure(_ error: Error, provider: String) -> AppFailure {
        guard let error = error as? URLError else {
            return AppFailure("Cannot reach \(provider). Check your connection and retry.", underlying: error)
        }
        let message: String.LocalizationValue
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            message = "Your Mac is offline or lost its connection. Reconnect, then retry."
        case .timedOut: message = "\(provider) did not respond in time. Retry in a moment."
        case .cannotFindHost, .dnsLookupFailed:
            message = "\(provider)’s server could not be found. Check your network or DNS settings, then retry."
        case .cannotConnectToHost:
            message = "\(provider) refused the connection. A firewall or proxy may be blocking it."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid,
            .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            message =
                "A secure connection to \(provider) could not be established. A proxy, VPN or security tool may be intercepting it."
        default: message = "Cannot reach \(provider). Check your connection and retry."
        }
        return AppFailure(message, underlying: error)
    }
    static var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        return config
    }
    public static func data(_ request: URLRequest, provider: String) async throws -> Data {
        try await data(request, provider: provider, configuration: configuration)
    }
    static func data(_ request: URLRequest, provider: String, configuration: URLSessionConfiguration) async throws
        -> Data
    {
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw AppFailure("\(provider) returned an invalid response.")
            }
            guard (200..<300).contains(response.statusCode) else {
                throw failure(status: response.statusCode, provider: provider)
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= maximumResponse else { throw AppFailure("\(provider) response was too large.") }
            }
            return data
        } catch let error as AppFailure { throw error } catch is CancellationError { throw CancellationError() } catch {
            // Cancelling the task surfaces from URLSession as URLError.cancelled.
            if Task.isCancelled { throw CancellationError() }
            throw transportFailure(error, provider: provider)
        }
    }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
