import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiProviders

final class CredentialsTests: XCTestCase {
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

    func testSignInPathThatIsAFIFOIsRejectedWithoutBlocking() throws {
        let folder = TestScratch.folder("g2-fifo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("auth.json")
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try Credentials.token(in: file, now: Date())) {
            XCTAssertEqual($0 as? Credentials.SignIn, .notOwned)
        }
        let regular = folder.appendingPathComponent("regular.json")
        try Data(#"{"tokens":{"access_token":"opaque"}}"#.utf8).write(to: regular)
        XCTAssertEqual(try Credentials.token(in: regular, now: Date()), "opaque")
        try Data(count: Credentials.maximumFileSize).write(to: regular)
        XCTAssertThrowsError(try Credentials.token(in: regular, now: Date())) {
            XCTAssertEqual($0 as? Credentials.SignIn, .unreadable)
        }
    }

    private func home() throws -> URL {
        let url = TestScratch.folder("mochi-home")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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

    private func jwt(expiring date: Date) -> String {
        func part(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString().replacingOccurrences(
                of: "=", with: ""
            ).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return part(["alg": "none"]) + "." + part(["exp": date.timeIntervalSince1970]) + ".signature"
    }
}
