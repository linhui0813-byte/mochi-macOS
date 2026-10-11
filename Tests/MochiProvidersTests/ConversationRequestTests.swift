import MochiKernel
import XCTest

@testable import MochiCore
@testable import MochiProviders

final class ConversationRequestTests: XCTestCase {
    func testPromptIsolationAndPrecedence() {
        let chat = ConversationRequest(history: [], text: "hello", instructions: "Give longer answers")
        XCTAssertTrue(chat.resolvedInstructions.contains("Give longer answers"))
        XCTAssertTrue(chat.resolvedInstructions.contains("override"))
        let help = ConversationRequest(history: [], text: "hello", help: true, instructions: "Interview me")
        let reference = ConversationRequest(history: [], text: "hello", reference: true, instructions: "Interview me")
        XCTAssertFalse(help.resolvedInstructions.contains("Interview me"))
        XCTAssertFalse(reference.resolvedInstructions.contains("Interview me"))
    }

    func testNamePromptAndReferenceIsolationAndGreetingPatterns() throws {
        var prefs = ConversationPreferences()
        prefs.coaching = .direct
        let prompt = VoiceIdentity.conversationInstructions(
            custom: "Your name is Sam", preferences: prefs, characterName: "Loki")
        XCTAssertTrue(prompt.contains("\"Loki\""))
        XCTAssertTrue(prompt.contains("previous names"))
        XCTAssertFalse(prompt.contains("pronounced MOH-chee"))
        let reference = ConversationRequest(
            history: [], text: "Say this", reference: true, instructions: "Your name is Sam", characterName: "Loki")
        XCTAssertFalse(reference.resolvedInstructions.contains("Loki"))
        var history: [String] = []
        for _ in 0..<30 {
            let greeting = VoiceIdentity.namedGreeting(name: "Loki", excluding: history)
            XCTAssertTrue(greeting.text.contains("Loki"))
            XCTAssertFalse(history.suffix(3).contains(greeting.pattern))
            history.append(greeting.pattern)
        }
    }

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

    func testInvalidVoiceMessageAudioIsRejectedBeforeSigningIn() async {
        for pcm in [Data(), Data(count: 4799), Data(count: 4801), Data(count: 65 * 48000 + 2)] {
            var signedIn = false
            do {
                _ = try await RealtimeService().reply(
                    ConversationRequest(history: [], text: "", pcm: pcm, spoken: true),
                    credential: {
                        signedIn = true
                        return "session"
                    },
                    connect: { _ in
                        XCTFail("connected")
                        return RealtimeChannel(send: { _ in }, receive: { [:] }, close: {})
                    })
                XCTFail("Accepted \(pcm.count) bytes")
            } catch {
                XCTAssertTrue(error is AppFailure)
            }
            XCTAssertFalse(signedIn)
        }
    }
}
