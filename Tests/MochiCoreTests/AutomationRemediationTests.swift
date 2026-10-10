import MochiAutomation
import MochiKernel
import XCTest

@testable import MochiCore

final class AutomationRemediationTests: XCTestCase {
    // MARK: Tool registry (M17)

    func testEveryToolIsDeclaredOnceWithConsistentRouting() {
        let external = MochiTools.catalog(origin: .external)
        let voice = MochiTools.catalog(origin: .voice)
        XCTAssertEqual(external.map(\.name), MochiToolName.allCases)
        XCTAssertEqual(
            Set(voice.map(\.name)),
            [
                .getSession, .getMessages, .prepareExpression, .startPractice, .saveExpression, .searchExpressions,
                .playAudio, .seekAudio, .setConversationPreferences,
            ])
        for tool in external {
            XCTAssertEqual(tool.properties["conversation_id"] != nil, tool.scope == .conversation, tool.name.rawValue)
            XCTAssertEqual(
                tool.properties["expected_revision"] != nil, !tool.readOnly && tool.scope != .catalog,
                tool.name.rawValue)
            XCTAssertEqual(
                tool.scope == .catalog,
                tool.name.rawValue.hasSuffix("_conversation_template") || tool.name == .listConversationTemplates,
                tool.name.rawValue)
            if tool.readOnly {
                XCTAssertTrue(tool.idempotent, tool.name.rawValue)
                XCTAssertFalse(tool.destructive, tool.name.rawValue)
            }
        }
        XCTAssertEqual(
            Set(external.filter(\.deferredDuringVoiceReply).map(\.name)),
            [.prepareExpression, .startPractice, .playAudio, .seekAudio])
        XCTAssertEqual(
            Set(external.filter(\.destructive).map(\.name)),
            [
                .setConversationInstructions, .setConversationPreferences, .updateConversationTemplate,
                .deleteConversationTemplate,
            ])
    }
    func testTypedArgumentsFailAsErrorsNotCrashes() {
        XCTAssertThrowsError(try MochiTools.decode(ConversationSettingsArguments.self, from: ["coaching": "shouting"]))
        { error in
            XCTAssertTrue(error is AppFailure)
        }
        XCTAssertThrowsError(try MochiTools.decode(ExpressionArguments.self, from: [:]))
        let audio = try? MochiTools.decode(
            AudioArguments.self, from: ["message_id": UUID().uuidString, "seconds": 2.5])
        XCTAssertEqual(audio?.seconds, 2.5)
        XCTAssertNotNil(audio?.messageID)
    }

    // MARK: Settings patch (M18)

    func testPatchTrimsValidatesAndAppliesAllOrNothing() throws {
        var chat = Conversation()
        chat.instructions = "Original"
        chat.characterName = "Loki"
        try ConversationSettingsPatch(
            instructions: "  Interview me  ", characterName: .set("  Sam "), speed: .set(0.8), coaching: .gentle
        ).apply(to: &chat)
        XCTAssertEqual(chat.instructions, "Interview me")
        XCTAssertEqual(chat.characterName, "Sam")
        XCTAssertEqual(chat.preferences.speed, 0.8)
        XCTAssertEqual(chat.preferences.coaching, .gentle)
        let before = chat
        XCTAssertThrowsError(
            try ConversationSettingsPatch(instructions: "Changed", characterName: .set("Bad\nName")).apply(to: &chat))
        XCTAssertEqual(chat.instructions, before.instructions)
        XCTAssertEqual(chat.characterName, before.characterName)
        XCTAssertThrowsError(try ConversationSettingsPatch(speed: .set(3)).apply(to: &chat))
        XCTAssertEqual(chat.preferences, before.preferences)
        try ConversationSettingsPatch(characterName: .clear, speed: .clear).apply(to: &chat)
        XCTAssertNil(chat.characterName)
        XCTAssertNil(chat.preferences.speed)
    }
    func testPatchFromToolArguments() throws {
        let patch = ConversationSettingsPatch(
            try MochiTools.decode(
                ConversationSettingsArguments.self, from: ["clear_character_name": true, "speed": 1.2]))
        XCTAssertEqual(patch, ConversationSettingsPatch(characterName: .clear, speed: .set(1.2)))
        XCTAssertTrue(
            ConversationSettingsPatch(try MochiTools.decode(ConversationSettingsArguments.self, from: [:])).isEmpty)
    }

    // MARK: Stdio framing (M26)

    func testFramerAcceptsTheLimitAndRecoversAfterAnOversizedLine() {
        var framer = MCPStdioFramer(limit: 8)
        XCTAssertEqual(framer.feed(Data("12345678\n".utf8)), [.request(Data("12345678".utf8))])
        XCTAssertEqual(framer.feed(Data("123456789".utf8)), [])
        XCTAssertEqual(framer.feed(Data("more\nok\n".utf8)), [.oversized, .request(Data("ok".utf8))])
        XCTAssertEqual(framer.feed(Data("\n".utf8)), [.request(Data())])
        XCTAssertEqual(framer.feed(Data("par".utf8)), [])
        XCTAssertEqual(framer.feed(Data("tial\nlast".utf8)), [.request(Data("partial".utf8))])
        XCTAssertEqual(framer.finish(), .request(Data("last".utf8)))
        XCTAssertNil(framer.finish())
        _ = framer.feed(Data(repeating: 65, count: 9))
        XCTAssertEqual(framer.finish(), .oversized)
    }
    func testHelperAnswersAnInteractiveClientWithoutWaitingForEndOfInput() throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mochi-mcp")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: helper.path), "Build the mochi-mcp product before testing")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        process.environment = ["MOCHI_CONTROL_SOCKET": "/nonexistent/mochi.sock"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let request =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
        input.fileHandleForWriting.write(Data((request + "\n").utf8))
        // Stdin stays open: a helper that waits for more input never answers.
        let answered = expectation(description: "Helper answered")
        var line = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            line.append(handle.availableData)
            if line.contains(10) {
                handle.readabilityHandler = nil
                answered.fulfill()
            }
        }
        wait(for: [answered], timeout: 5)
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.prefix { $0 != 10 }) as? [String: Any])
        XCTAssertEqual((reply["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertTrue(
            ((reply["result"] as? [String: Any])?["instructions"] as? String)?.contains("untrusted_fields") == true)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    func testBridgeFailuresAreDiagnosedOnTheSideChannel() throws {
        var lines: [String] = []
        let server = MochiMCPProtocol(
            bridge: { _ in throw AppFailure("Open Mochi first.") }, diagnostics: { lines.append($0) })
        _ = server.respond(
            try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": [:]],
            ]))
        _ = server.respond(
            try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        let reply = try XCTUnwrap(
            server.respond(
                try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                    "params": ["name": "get_session", "arguments": [:]],
                ])))
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).contains("Open Mochi first."))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("get_session"))
    }
}
