#if MOCHI_DEVELOPMENT
    import Foundation
    import MochiKernel
    import MochiAutomation

    /// Only used by --smoke-test, with a temporary library and socket; no provider traffic.
    enum AutomationSmokeClient {
        private final class Client {
            let process = Process(), input = Pipe(), output = Pipe()
            var transcript: [[String: Any]] = []
            init(helper: String, socketPath: String) throws {
                process.executableURL = URL(fileURLWithPath: helper)
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                var environment = ProcessInfo.processInfo.environment
                environment["MOCHI_CONTROL_SOCKET"] = socketPath
                process.environment = environment
                try process.run()
            }
            deinit {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { usleep(20000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            func write(_ object: [String: Any]) throws {
                try input.fileHandleForWriting.write(
                    contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
            }
            /// One newline-terminated message from the helper, read before `deadline`.
            private func readLine(before deadline: Date) throws -> Data {
                var data = Data()
                let fd = output.fileHandleForReading.fileDescriptor
                while true {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else { throw AppFailure("MCP helper timed out.") }
                    var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&item, 1, Int32(max(1, min(1000, remaining * 1000))))
                    if ready < 0 {
                        if errno == EINTR { continue }
                        throw AppFailure("Could not wait for the MCP helper: \(String(cString: strerror(errno))).")
                    }
                    if ready == 0 { continue }
                    guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
                        throw AppFailure("MCP helper ended.")
                    }
                    if byte[byte.startIndex] == 10 { return data }
                    data.append(byte)
                    guard data.count <= LocalControl.maxFrame else {
                        throw AppFailure("MCP helper response exceeded limit.")
                    }
                }
            }
            /// The JSON-RPC response to request `id`. Notifications that arrive first are recorded and skipped.
            func request(_ method: String, id: Int, params: [String: Any] = [:]) throws -> [String: Any] {
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
                let deadline = Date().addingTimeInterval(10)
                while true {
                    let line = try readLine(before: deadline)
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw AppFailure("Invalid MCP helper JSON.")
                    }
                    transcript.append(object)
                    guard object["jsonrpc"] as? String == "2.0" else {
                        throw AppFailure("MCP helper sent a message that is not JSON-RPC 2.0.")
                    }
                    if object["id"] == nil, object["method"] is String { continue }
                    guard let number = object["id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                        number.intValue == id, number.doubleValue == Double(id)
                    else { throw AppFailure("MCP helper answered a different request than \(method) #\(id).") }
                    return object
                }
            }
            func initialize() throws {
                _ = try request(
                    "initialize", id: 1,
                    params: [
                        "protocolVersion": "2025-06-18", "clientInfo": ["name": "mochi-native-smoke", "version": "1"],
                        "capabilities": [:],
                    ])
                try write(["jsonrpc": "2.0", "method": "notifications/initialized"])
            }
            /// The tool's decoded JSON payload and whether the helper flagged it as an error.
            func tool(_ name: String, id: Int, arguments: [String: Any]) throws -> (
                isError: Bool, object: [String: Any]
            ) {
                let response = try request("tools/call", id: id, params: ["name": name, "arguments": arguments])
                guard let result = response["result"] as? [String: Any], let isError = result["isError"] as? Bool,
                    let content = result["content"] as? [[String: Any]], let text = content.first?["text"] as? String,
                    let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                else { throw AppFailure("MCP helper returned an unreadable \(name) result.") }
                return (isError, object)
            }
            func call(_ name: String, id: Int, arguments: [String: Any] = [:]) throws -> [String: Any] {
                let (isError, object) = try tool(name, id: id, arguments: arguments)
                guard !isError, object["ok"] as? Bool == true else {
                    throw AppFailure("MCP helper \(name) failed: \(object["error"] as? String ?? "no message").")
                }
                return object
            }
            /// The current conversation revision, which every conversation action must quote.
            func revision() throws -> String {
                guard let revision = try call("get_session", id: 9)["revision"] as? String else {
                    throw AppFailure("MCP session missing revision.")
                }
                return revision
            }
        }
        static func run(helper: String, socketPath: String) throws -> Data {
            let client = try Client(helper: helper, socketPath: socketPath)
            try client.initialize()
            let list = try client.request("tools/list", id: 2)
            guard
                ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count
                    == MochiTools.catalog(origin: .external).count
            else { throw AppFailure("MCP tools were not discovered.") }
            let session = try client.call("get_session", id: 3)
            guard let id = session["conversation_id"] as? String, let revision = session["revision"] as? String else {
                throw AppFailure("MCP session missing state.")
            }
            try checkExpressionReplay(client, conversation: id, revision: revision)
            let template = try checkTemplateLifecycle(client)
            try checkSnapshotSurvivesDeletion(client, template: template, conversation: id)
            return try JSONSerialization.data(
                withJSONObject: client.transcript, options: [.prettyPrinted, .sortedKeys])
        }
        /// A request repeated with the same JSON-RPC ID gets the first reply and changes nothing.
        private static func checkExpressionReplay(_ client: Client, conversation id: String, revision: String) throws {
            let arguments: [String: Any] = [
                "conversation_id": id, "expected_revision": revision, "english": "Could you give me a moment?",
                "meaning": "Ask politely for time to think.",
            ]
            let first = try client.call("save_expression", id: 4, arguments: arguments)
            let replay = try client.call("save_expression", id: 4, arguments: arguments)
            guard let saved = first["expression_id"] as? String, replay["expression_id"] as? String == saved,
                let savedRevision = first["revision"] as? String, replay["revision"] as? String == savedRevision
            else { throw AppFailure("MCP replay returned a different result.") }
            guard try client.call("get_session", id: 40)["revision"] as? String == savedRevision else {
                throw AppFailure("MCP replay changed Mochi's state.")
            }
        }
        /// Creates and updates a user template, and checks that a stale revision is refused for that reason.
        private static func checkTemplateLifecycle(_ client: Client) throws -> (id: String, revision: String) {
            let catalog = try client.call("list_conversation_templates", id: 5)
            guard (catalog["templates"] as? [[String: Any]])?.count ?? 0 >= 6 else {
                throw AppFailure("Built-in templates missing.")
            }
            let created = try client.call(
                "create_conversation_template", id: 6, arguments: ["title": "MCP Loki", "character_name": "Loki"])
            guard let template = created["template"] as? [String: Any], let templateID = template["id"] as? String,
                let templateRevision = template["template_revision"] as? String
            else { throw AppFailure("Template create failed.") }
            _ = try client.call("get_conversation_template", id: 7, arguments: ["template_id": templateID])
            let updated = try client.call(
                "update_conversation_template", id: 8,
                arguments: [
                    "template_id": templateID, "expected_template_revision": templateRevision,
                    "instructions": "Discuss books",
                ])
            guard let updatedRevision = (updated["template"] as? [String: Any])?["template_revision"] as? String,
                updatedRevision != templateRevision
            else { throw AppFailure("Template update did not return a new revision.") }
            let stale = try client.tool(
                "update_conversation_template", id: 80,
                arguments: [
                    "template_id": templateID, "expected_template_revision": templateRevision,
                    "instructions": "Stale overwrite",
                ])
            guard stale.isError, (stale.object["error"] as? String)?.hasPrefix("This template changed.") == true else {
                throw AppFailure("Stale helper update was not refused as a revision conflict.")
            }
            let unchanged = try client.call("get_conversation_template", id: 81, arguments: ["template_id": templateID])
            guard let current = unchanged["template"] as? [String: Any],
                current["instructions"] as? String == "Discuss books",
                current["template_revision"] as? String == updatedRevision
            else { throw AppFailure("Stale request changed the template.") }
            return (templateID, updatedRevision)
        }
        /// A conversation started from a template keeps its settings after the template is deleted.
        private static func checkSnapshotSurvivesDeletion(
            _ client: Client, template: (id: String, revision: String), conversation id: String
        ) throws {
            _ = try client.call(
                "create_conversation", id: 10,
                arguments: [
                    "template_id": template.id, "expected_template_revision": template.revision,
                    "expected_revision": try client.revision(),
                ])
            _ = try client.call(
                "delete_conversation_template", id: 11,
                arguments: ["template_id": template.id, "expected_template_revision": template.revision])
            let snapshot = try client.call("get_session", id: 12)
            guard snapshot["character_name"] as? String == "Loki",
                snapshot["instructions"] as? String == "Discuss books",
                let revision = snapshot["revision"] as? String
            else { throw AppFailure("Conversation lost deleted template snapshot.") }
            _ = try client.call(
                "open_conversation", id: 13, arguments: ["conversation_id": id, "expected_revision": revision])
        }
        static func disabled(helper: String, socketPath: String) throws -> Bool {
            let client = try Client(helper: helper, socketPath: socketPath)
            try client.initialize()
            let response = try client.request("tools/call", id: 2, params: ["name": "get_session", "arguments": [:]])
            return (response["result"] as? [String: Any])?["isError"] as? Bool == true
        }
    }

#endif
