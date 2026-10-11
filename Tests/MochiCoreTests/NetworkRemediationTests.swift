import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

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

final class NetworkRemediationTests: XCTestCase {
    private func home() throws -> URL {
        let url = TestScratch.folder("mochi-home")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func jwt(expiring date: Date) -> String {
        func part(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString().replacingOccurrences(
                of: "=", with: ""
            ).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return part(["alg": "none"]) + "." + part(["exp": date.timeIntervalSince1970]) + ".signature"
    }
    private func token(home: URL, environment: [String: String] = [:]) async -> Result<String, AppFailure> {
        do {
            return .success(
                try await Credentials.codexToken(environment: environment, home: home, now: Date(), retryDelay: 0))
        } catch { return .failure(error as! AppFailure) }
    }
    private func write(_ text: String, to home: URL) throws {
        try Data(text.utf8).write(to: home.appendingPathComponent(".codex/auth.json"))
    }

    // MARK: Codex sign-in (M2, L9)

    func testSignInProblemsAreToldApart() async throws {
        let home = try home()
        let cases: [(String?, Credentials.SignIn)] = [
            (nil, .missing),
            (String(repeating: "x", count: Credentials.maximumFileSize + 1), .unreadable),
            ("[1,2,3]", .unrecognized),
            (#"{"tokens":{"access_token":""}}"#, .unrecognized),
            (#"{"OPENAI_API_KEY":"sk-test","tokens":null}"#, .apiKeyOnly),
            (#"{"tokens":{"access_token":"\#(jwt(expiring:Date(timeIntervalSinceNow:-60)))"}}"#, .expired),
        ]
        for (content, expected) in cases {
            let file = home.appendingPathComponent(".codex/auth.json")
            try? FileManager.default.removeItem(at: file)
            if let content { try write(content, to: home) }
            let result = await token(home: home)
            XCTAssertEqual(try? result.get(), nil, "\(expected)")
            if case .failure(let failure) = result { XCTAssertEqual(failure.message, expected.failure.message) }
        }
    }
    func testValidJWTAndOpaqueTokensAreAccepted() async throws {
        let home = try home()
        let fresh = jwt(expiring: Date(timeIntervalSinceNow: 3600))
        try write(#"{"tokens":{"access_token":"\#(fresh)"}}"#, to: home)
        let accepted = try await token(home: home).get()
        XCTAssertEqual(accepted, fresh)
        try write(#"{"tokens":{"access_token":"opaque-token"}}"#, to: home)
        let opaque = try await token(home: home).get()
        XCTAssertEqual(opaque, "opaque-token")
    }
    func testSymlinkedSignInFileIsNotRead() async throws {
        let home = try home()
        let elsewhere = home.appendingPathComponent("other.json")
        try Data(#"{"tokens":{"access_token":"planted"}}"#.utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".codex/auth.json"), withDestinationURL: elsewhere)
        let result = await token(home: home)
        XCTAssertNil(try? result.get())
        if case .failure(let failure) = result {
            XCTAssertEqual(failure.message, Credentials.SignIn.notOwned.failure.message)
        }
    }
    func testCodexHomeIsHonouredOnlyInsideTheHomeFolder() async throws {
        let home = try home()
        let custom = home.appendingPathComponent("custom-codex")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"custom"}}"#.utf8).write(to: custom.appendingPathComponent("auth.json"))
        let honoured = try await token(home: home, environment: ["CODEX_HOME": custom.path]).get()
        XCTAssertEqual(honoured, "custom")
        let outside = try self.home()
        let result = await token(home: home, environment: ["CODEX_HOME": outside.appendingPathComponent(".codex").path])
        if case .failure(let failure) = result {
            XCTAssertEqual(failure.message, Credentials.SignIn.untrustedCodexHome.failure.message)
        } else {
            XCTFail("Outside CODEX_HOME was honoured")
        }
        let link = home.appendingPathComponent("link-out")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: outside.appendingPathComponent(".codex"))
        let linked = await token(home: home, environment: ["CODEX_HOME": link.path])
        XCTAssertNil(try? linked.get())
    }

    // MARK: HTTP transport (M5, M14)

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

    // MARK: Realtime session (M14, M1, L3)

    @MainActor func testReplyHandshakeSendsBoundedHistoryAndChunkedAudio() async throws {
        var sent: [[String: Any]] = []
        var events: [[String: Any]] = [
            ["type": "session.created"], ["type": "session.updated"],
            ["type": "input_audio_buffer.committed", "item_id": "one"],
            [
                "type": "conversation.item.input_audio_transcription.completed", "item_id": "one",
                "transcript": "Spoken words",
            ],
            ["type": "response.output_text.delta", "delta": "Hi."],
            ["type": "response.done", "response": ["status": "completed"]],
        ]
        let channel = RealtimeChannel(send: { sent.append($0) }, receive: { events.removeFirst() }, close: {})
        let history = (0..<31).map { Message(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "Message \($0)") }
        let request = ConversationRequest(history: history, text: "", pcm: Data(count: 100_000), spoken: true)
        var requested: URLRequest?
        let reply = try await RealtimeService(model: "test-model").reply(
            request, credential: { "session" },
            connect: {
                requested = $0
                return channel
            })
        XCTAssertEqual(reply.text, "Hi.")
        XCTAssertEqual(reply.inputTranscript, "Spoken words")
        XCTAssertEqual(requested?.value(forHTTPHeaderField: "Authorization"), "Bearer session")
        let types = sent.map { $0["type"] as? String ?? "" }
        XCTAssertEqual(types.first, "session.update")
        XCTAssertEqual(types.filter { $0 == "conversation.item.create" }.count, 30)
        XCTAssertEqual(types.filter { $0 == "input_audio_buffer.append" }.count, 3)
        XCTAssertEqual(Array(types.suffix(2)), ["input_audio_buffer.commit", "response.create"])
        XCTAssertEqual(
            (sent.last?["response"] as? [String: Any])?["max_output_tokens"] as? Int,
            RealtimeService.maximumOutputTokens)
    }
    func testReplyStoppedAtTheLengthLimitIsKeptAndMarked() throws {
        var reply = RealtimeAccumulator()
        try reply.accept(["type": "response.output_text.delta", "delta": "A long answer"])
        try reply.accept([
            "type": "response.done",
            "response": ["status": "incomplete", "status_details": ["reason": "max_output_tokens"]],
        ])
        XCTAssertTrue(reply.done)
        XCTAssertTrue(reply.truncated)
        XCTAssertEqual(reply.text, "A long answer")
        var other = RealtimeAccumulator()
        XCTAssertThrowsError(
            try other.accept([
                "type": "response.done",
                "response": ["status": "incomplete", "status_details": ["reason": "content_filter"]],
            ]))
    }
    @MainActor func testToolRoundsDoNotRunTogether() async throws {
        var events: [[String: Any]] = [
            ["type": "response.output_text.delta", "delta": "Let me save that."],
            [
                "type": "response.done",
                "response": [
                    "status": "completed",
                    "output": [["type": "function_call", "call_id": "a", "name": "get_session", "arguments": "{}"]],
                ],
            ],
            ["type": "response.output_text.delta", "delta": "Saved!"],
            ["type": "response.done", "response": ["status": "completed"]],
        ]
        let reply = try await RealtimeService.deliverResponse(
            RealtimeAccumulator(), receive: { events.removeFirst() }, onResponse: nil, onTranscription: nil,
            onTool: { _, _, _ in ["ok": true] }, send: { _ in })
        XCTAssertEqual(reply.text, "Let me save that.\nSaved!")
    }
    func testCachedExampleIsReusedWithoutAReply() async throws {
        let root = TestScratch.folder("mochi-cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RealtimeService()
        let cached = root.appendingPathComponent(
            ReferenceSpeech.cacheName(text: "Hello.", model: service.model, voice: service.voice))
        try Data([1]).write(to: cached)
        let url = try await service.referenceAudio(text: "Hello.", root: root, force: false) { _ in
            XCTFail("A cached example must not be regenerated")
            throw AppFailure("no")
        }
        XCTAssertEqual(url, cached)
        var replied = false
        _ = try? await service.referenceAudio(text: "Hello.", root: root, force: true) { _ in
            replied = true
            throw AppFailure("offline")
        }
        XCTAssertTrue(replied)
    }
}
