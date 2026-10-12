import CoreFoundation
import Foundation
import MochiKernel

/// A deliberately pinned MCP stdio server for the handshake revisions up to 2025-11-25, independent of app/UI
/// lifetimes. A client of the stateless 2026 revisions probes with `server/discover`, is told the method is not
/// found, and falls back to `initialize`.
public final class MochiMCPProtocol {
    private var initialized = false, ready = false
    private let clientID = UUID().uuidString
    private let bridge: (Data) throws -> Data
    private let diagnostics: (String) -> Void
    /// `diagnostics` receives one line per failed bridge call; the helper writes it to stderr, never stdout.
    public init(
        bridge: @escaping (Data) throws -> Data = { try LocalControl.request($0) },
        diagnostics: @escaping (String) -> Void = { _ in }
    ) {
        self.bridge = bridge
        self.diagnostics = diagnostics
    }
    /// The app version when the helper runs inside Mochi.app; "development" for a bare build.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
    /// The response to a request line that exceeded the frame limit.
    public func oversizedResponse() -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Request exceeds the size limit."],
        ])
    }
    public func respond(_ data: Data) -> Data? {
        var id: Any = NSNull()
        func error(_ code: Int, _ message: String) -> Data? {
            try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message],
            ])
        }
        guard data.count <= LocalControl.maxFrame else { return error(-32600, "Request exceeds the size limit.") }
        // Scalars parse, so valid JSON that is not a request object is reported as an invalid request.
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return error(-32700, "Parse error.")
        }
        guard let request = parsed as? [String: Any], request["jsonrpc"] as? String == "2.0",
            let method = request["method"] as? String
        else { return error(-32600, "Invalid request.") }
        guard let requestID = request["id"] else {
            notify(method, params: request["params"])
            return nil
        }
        guard Self.validID(requestID) else { return error(-32600, Self.idProblem(requestID)) }
        id = requestID
        guard request["params"] == nil || request["params"] is [String: Any] else {
            return error(-32602, "Parameters must be an object.")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            guard !initialized, let requested = params["protocolVersion"] as? String,
                let client = params["clientInfo"] as? [String: Any], client["name"] is String,
                client["version"] is String, params["capabilities"] is [String: Any]
            else { return error(-32602, "Invalid initialization.") }
            initialized = true
            result = [
                "protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "mochi", "title": "Mochi", "version": Self.version,
                    "description": "Conversation practice in the running Mochi app on this Mac.",
                ],
                "instructions":
                    "Control the running Mochi app. External control must be enabled in Settings. Read get_session before conversation mutations and pass its revision as expected_revision; every result returns the new revision. Conversation tools act on the open conversation; open_conversation, rename_conversation and archive_conversation take any active conversation ID from list_conversations. Template tools (*_conversation_template) work without an open conversation, use template_id and expected_template_revision, and do not accept expected_revision. list_characters reads the user's characters; copy a character's name, personality and voice into a conversation or template to use it. A failed call explains what to change before retrying. Recording is always user initiated. "
                    + MochiTools.untrustedTextNotice,
            ]
        case "ping": result = [:]
        case "tools/list":
            guard ready else { return error(-32002, "Initialize the server first.") }
            result = ["tools": MochiTools.catalog(origin: .external).map(\.mcp)]
        case "tools/call":
            guard ready else { return error(-32002, "Initialize the server first.") }
            guard let name = params["name"] as? String else { return error(-32602, "Tool name required.") }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return error(-32602, "Arguments must be an object.")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard MochiTools.catalog(origin: .external).contains(where: { $0.name.rawValue == name }) else {
                return error(-32602, "Unknown tool name.")
            }
            // Invalid arguments are a tool error, not a protocol error, so the model sees why and can correct them.
            do {
                _ = try MochiTools.validate(name: name, arguments: arguments, origin: .external)
                result = callTool(name, arguments: arguments, id: requestID)
            } catch let failure {
                result = Self.toolError(AppFailure.message(for: failure, fallback: "Invalid tool arguments."))
            }
        default: return error(-32601, "Method not found.")
        }
        return try? JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: [.sortedKeys])
    }
    /// Newest first; a client asking for any other revision is offered the newest.
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private static func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
    /// Notifications are never answered; a malformed one is discarded without changing state.
    private func notify(_ method: String, params: Any?) {
        guard params == nil || params is [String: Any] else { return }
        if method == "notifications/initialized" && initialized { ready = true }
    }
    /// MCP request IDs are strings or integers of any size; booleans, fractions and other JSON values are refused.
    /// Integers parse as integer numbers, or as exact decimals beyond 64 bits, and both are echoed back unchanged.
    /// A number parsed as a Double cannot prove its literal had no fraction (`1.0`, `1e3`, `2^53 + 0.5`).
    static func validID(_ id: Any) -> Bool {
        if let text = id as? String { return text.count <= 200 }
        if let decimal = id as? NSDecimalNumber {
            let whole = decimal.rounding(
                accordingToBehavior: NSDecimalNumberHandler(
                    roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false,
                    raiseOnUnderflow: false, raiseOnDivideByZero: false))
            return decimal == whole
        }
        guard let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType))
    }
    private static func idProblem(_ id: Any) -> String {
        id is String ? "Request ID is too long." : "Invalid request ID."
    }
    /// Forwards a validated call to the app; bridge failures become tool errors, diagnosed on stderr.
    /// A successful result is returned twice: as `structuredContent` matching the tool's output schema, and as its
    /// serialized text for clients that read only text.
    private func callTool(_ name: String, arguments: [String: Any], id: Any) -> [String: Any] {
        do {
            let payload: [String: Any] = [
                "name": name, "arguments": arguments,
                "request_id": clientID + ":" + (try MochiTools.signature(name: "mcp_request", arguments: ["id": id])),
            ]
            let response = try bridge(JSONSerialization.data(withJSONObject: payload))
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
                throw AppFailure("Invalid app control response.")
            }
            let succeeded = object["ok"] as? Bool == true
            var result: [String: Any] = [
                "content": [["type": "text", "text": try MochiTools.encode(object)]], "isError": !succeeded,
            ]
            if succeeded { result["structuredContent"] = object }
            return result
        } catch {
            diagnostics("mochi-mcp: \(name) failed: \(String(describing:error))")
            return Self.toolError(AppFailure.message(for: error, fallback: "Mochi could not execute this action."))
        }
    }
}
