import MochiKernel
import XCTest

@testable import MochiProviders

/// Serves one canned response per test without touching the network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, body: Data)?
    nonisolated(unsafe) static var failure: URLError?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let (status, body) = Self.response ?? (200, Data())
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Never answers, so a request stays in flight until the task is cancelled.
private final class SilentProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

final class ServiceHTTPTests: XCTestCase {
    func testHTTPOutcomesAreReportedPrecisely() async throws {
        defer {
            StubProtocol.response = nil
            StubProtocol.failure = nil
        }
        StubProtocol.response = (200, Data("ok".utf8))
        let body = try await fetch().get()
        XCTAssertEqual(body, Data("ok".utf8))
        StubProtocol.response = (302, Data())
        if case .failure(let f) = await fetch() {
            XCTAssertTrue(f.message.contains("redirected"))
        } else {
            XCTFail("Redirect accepted")
        }
        StubProtocol.response = (200, Data(count: ServiceHTTP.maximumResponse + 1))
        if case .failure(let f) = await fetch() {
            XCTAssertTrue(f.message.contains("too large"))
        } else {
            XCTFail("Oversized body accepted")
        }
        StubProtocol.failure = URLError(.notConnectedToInternet)
        if case .failure(let f) = await fetch() {
            XCTAssertTrue(f.message.contains("offline"))
            XCTAssertTrue(f.underlying is URLError)
        } else {
            XCTFail("Offline succeeded")
        }
    }

    func testTransportFailuresAreToldApart() {
        let messages = [
            URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
            .serverCertificateUntrusted, .badURL,
        ]
        .map { ServiceHTTP.transportFailure(URLError($0), provider: "OpenAI").message }
        XCTAssertEqual(Set(messages).count, messages.count)
        XCTAssertTrue(messages[4].contains("intercepting"))
    }

    func testStatusMessagesAreExact() {
        XCTAssertEqual(
            ServiceHTTP.failure(status: 401, provider: "OpenAI").message,
            "Your Codex sign-in was rejected. Sign in through Codex again, then retry.")
        XCTAssertEqual(
            ServiceHTTP.failure(status: 401, provider: "Voice").message,
            "Voice credentials were rejected. Update them in Settings.")
        XCTAssertEqual(
            ServiceHTTP.failure(status: 403, provider: "OpenAI").message, "This account does not have access to OpenAI."
        )
        XCTAssertEqual(
            ServiceHTTP.failure(status: 429, provider: "OpenAI").message, "OpenAI usage limit reached. Retry later.")
        XCTAssertEqual(
            ServiceHTTP.failure(status: 500, provider: "OpenAI").message,
            "OpenAI request failed (HTTP 500). Check Settings and retry.")
    }

    func testCancelledHTTPRequestThrowsCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentProtocol.self]
        let request = URLRequest(url: URL(string: "https://example.invalid/never")!)
        let task = Task { try await ServiceHTTP.data(request, provider: "OpenAI", configuration: configuration) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled request returned data")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    private func fetch() async -> Result<Data, AppFailure> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        do {
            return .success(
                try await ServiceHTTP.data(
                    URLRequest(url: URL(string: "https://api.openai.com/test")!), provider: "OpenAI",
                    configuration: configuration))
        } catch { return .failure(error as! AppFailure) }
    }
}
