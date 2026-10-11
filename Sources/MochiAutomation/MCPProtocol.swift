import CoreFoundation
import Foundation
import MochiKernel

/// A deliberately pinned MCP 2025-06-18 stdio server, independent of app/UI lifetimes.
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
            let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
            result = [
                "protocolVersion": supported.contains(requested) ? requested : "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "mochi", "version": Self.version],
                "instructions":
                    "Control the running Mochi app. External control must be enabled in Settings. Read get_session before conversation mutations and pass its revision as expected_revision. Scope conversation operations to the open conversation. Template tools (*_conversation_template) work without an open conversation, use template_id and expected_template_revision, and do not accept expected_revision. Recording is always user initiated. "
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
            do { _ = try MochiTools.validate(name: name, arguments: arguments, origin: .external) } catch let failure {
                return error(-32602, AppFailure.message(for: failure, fallback: "Invalid tool arguments."))
            }
            result = callTool(name, arguments: arguments, id: requestID)
        default: return error(-32601, "Method not found.")
        }
        return try? JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: [.sortedKeys])
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
            return [
                "content": [["type": "text", "text": try MochiTools.encode(object)]],
                "isError": object["ok"] as? Bool != true,
            ]
        } catch {
            diagnostics("mochi-mcp: \(name) failed: \(String(describing:error))")
            return [
                "content": [
                    [
                        "type": "text",
                        "text": AppFailure.message(for: error, fallback: "Mochi could not execute this action."),
                    ]
                ], "isError": true,
            ]
        }
    }
}
