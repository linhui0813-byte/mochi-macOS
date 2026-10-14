import MochiCore
import XCTest

@testable import MochiProviders

@MainActor private final class ConversationSocket {
    var events: [[String: Any]] = [["type": "session.created"]]
    var sent: [[String: Any]] = []
    var closed = false
    var nextID = 0
    var onClose: (() -> Void)?
    var pingFails = false
    var pingCount = 0
    var failResponse = false
    var failSession = false
    var channel: RealtimeChannel {
        RealtimeChannel(
            send: { event in
                guard !self.closed else { throw URLError(.networkConnectionLost) }
                self.sent.append(event)
                switch event["type"] as? String {
                case "session.update":
                    self.events.append(
                        self.failSession
                            ? ["type": "error", "error": ["code": "rate_limit_exceeded"]]
                            : ["type": "session.updated"])
                case "conversation.item.delete":
                    self.events.append(["type": "conversation.item.deleted", "item_id": event["item_id"]!])
                case "conversation.item.create":
                    self.nextID += 1
                    self.events.append(["type": "conversation.item.added", "item": ["id": "item-\(self.nextID)"]])
                case "response.create":
                    if self.failResponse {
                        self.events.append(["type": "error", "error": ["code": "rate_limit_exceeded"]])
                        return
                    }
                    self.nextID += 1
                    self.events += [
                        ["type": "response.output_audio.delta", "delta": Data([0, 0, 2, 0]).base64EncodedString()],
                        ["type": "response.output_audio_transcript.delta", "delta": "Hello"],
                        [
                            "type": "response.done",
                            "response": ["status": "completed", "output": [["id": "item-\(self.nextID)"]]],
                        ],
                    ]
                default: break
                }
            },
            receive: {
                guard !self.closed, !self.events.isEmpty else { throw URLError(.networkConnectionLost) }
                return self.events.removeFirst()
            },
            close: {
                Task { @MainActor in
                    guard !self.closed else { return }
                    self.closed = true
                    self.onClose?()
                }
            },
            ping: {
                self.pingCount += 1
                if self.pingFails { throw URLError(.networkConnectionLost) }
            })
    }
}

final class StreamingConnectionTests: XCTestCase {
    @MainActor func testAudioChunksReachPlaybackBeforeResponseDoneAndAreStillAccumulated() async throws {
        let chunks = [Data([0, 1]), Data([2, 3])]
        var events: [[String: Any]] =
            chunks.map {
                ["type": "response.output_audio.delta", "delta": $0.base64EncodedString()]
            } + [["type": "response.done", "response": ["status": "completed"]]]
        var order: [String] = []
        var received = Data()
        let result = try await RealtimeService.deliverResponse(
            RealtimeAccumulator(), receive: { events.removeFirst() },
            onResponse: { _ in order.append("response") }, onTranscription: nil,
            onAudio: { chunk in
                XCTAssertFalse(events.isEmpty, "Playback must not wait for the last server event")
                order.append("audio")
                received.append(chunk)
            })
        XCTAssertEqual(order, ["audio", "audio", "response"])
        XCTAssertEqual(received, Data([0, 1, 2, 3]))
        XCTAssertEqual(result.audio, received, "Replay must retain every streamed byte")
    }
    @MainActor func testTimingDistinguishesFirstAudioFromFullResponseAndTranscription() async throws {
        let timing = VoiceReplyTiming()
        timing.record(.submitted)
        var events: [[String: Any]] = [
            ["type": "session.created"], ["type": "session.updated"],
            ["type": "input_audio_buffer.committed", "item_id": "voice"],
            ["type": "response.output_audio.delta", "delta": Data([0, 0, 1, 0]).base64EncodedString()],
            ["type": "response.done", "response": ["status": "completed"]],
            ["type": "conversation.item.input_audio_transcription.completed", "item_id": "voice", "transcript": "Hi"],
        ]
        _ = try await RealtimeService().reply(
            ConversationRequest(
                history: [], text: "", pcm: Data(repeating: 0, count: 4800), spoken: true, voiceTiming: timing),
            credential: { "test-session" },
            connect: { _ in RealtimeChannel(send: { _ in }, receive: { events.removeFirst() }, close: {}) },
            onAudio: { _ in
                XCTAssertNotNil(timing.elapsedMilliseconds(at: .firstAudio))
                XCTAssertNil(timing.elapsedMilliseconds(at: .responseFinished))
                XCTAssertNil(timing.elapsedMilliseconds(at: .transcriptionFinished))
            })
        for stage: VoiceReplyTiming.Stage in [
            .connectionNew, .credentialReady, .socketReady, .sessionReady, .audioSent, .responseRequested, .firstAudio,
            .responseFinished, .transcriptionFinished,
        ] {
            XCTAssertNotNil(timing.elapsedMilliseconds(at: stage), "Missing timing for \(stage)")
        }
    }
    @MainActor func testContinuousModeReusesSocketAndReplacesOldContextWithoutDuplicates() async throws {
        var sockets: [ConversationSocket] = []
        var credentials = 0
        let connection = RealtimeConversationConnection(
            credential: { _ in
                credentials += 1
                return "test"
            },
            connect: { _ in
                let socket = ConversationSocket()
                sockets.append(socket)
                return socket.channel
            })
        defer { connection.reset() }
        let id = UUID()
        let service = RealtimeService(reuseConnection: true)
        _ = try await connection.reply(
            service: service, input: ConversationRequest(history: [], text: "First", conversationID: id))
        _ = try await connection.reply(
            service: service,
            input: ConversationRequest(
                history: [Message(role: "user", text: "Edited context")], text: "Second", conversationID: id))
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(credentials, 1)
        XCTAssertEqual(sockets[0].pingCount, 0)
        XCTAssertEqual(sockets[0].sent.filter { $0["type"] as? String == "session.update" }.count, 2)
        let sent = sockets[0].sent
        XCTAssertEqual(sent.filter { $0["type"] as? String == "conversation.item.delete" }.count, 2)
        let messages = sent.filter { $0["type"] as? String == "conversation.item.create" }
        let texts = messages.compactMap {
            (($0["item"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        }
        XCTAssertEqual(texts, ["First", "Edited context", "Second"])
    }
    @MainActor func testReconnectModeUsesANewSocketForEveryMessage() async throws {
        var count = 0
        let connection = RealtimeConversationConnection(
            credential: { _ in "test" },
            connect: { _ in
                count += 1
                return ConversationSocket().channel
            })
        let request = ConversationRequest(history: [], text: "Hello", conversationID: UUID())
        for _ in 0..<2 { _ = try await connection.reply(service: RealtimeService(), input: request) }
        XCTAssertEqual(count, 2)
    }
    @MainActor func testConversationVoiceModelAndExplicitResetEachRequireAFreshConnection() async throws {
        var count = 0
        let connection = RealtimeConversationConnection(
            credential: { _ in "test" },
            connect: { _ in
                count += 1
                return ConversationSocket().channel
            })
        defer { connection.reset() }
        var request = ConversationRequest(history: [], text: "Hello", conversationID: UUID())
        var service = RealtimeService(reuseConnection: true)
        _ = try await connection.reply(service: service, input: request)
        request.conversationID = UUID()
        _ = try await connection.reply(service: service, input: request)
        service.voice = "cedar"
        _ = try await connection.reply(service: service, input: request)
        service.model = "another-model"
        _ = try await connection.reply(service: service, input: request)
        connection.reset()
        _ = try await connection.reply(service: service, input: request)
        XCTAssertEqual(count, 5)
    }
    @MainActor func testIdleTimeoutClosesTheConnectionAndTheNextTurnReconnects() async throws {
        let closed = expectation(description: "Idle connection closed")
        var sockets: [ConversationSocket] = []
        let connection = RealtimeConversationConnection(
            credential: { _ in "test" },
            connect: { _ in
                let socket = ConversationSocket()
                if sockets.isEmpty { socket.onClose = { closed.fulfill() } }
                sockets.append(socket)
                return socket.channel
            }, idleNanoseconds: 10_000_000)
        defer { connection.reset() }
        let service = RealtimeService(reuseConnection: true)
        let request = ConversationRequest(history: [], text: "Hello", conversationID: UUID())
        _ = try await connection.reply(service: service, input: request)
        await fulfillment(of: [closed], timeout: 2)
        _ = try await connection.reply(service: service, input: request)
        XCTAssertEqual(sockets.count, 2)
    }
    @MainActor func testServerFailureInvalidatesTheConnectionWithoutReplayingTheFailedTurn() async throws {
        var sockets: [ConversationSocket] = []
        let connection = RealtimeConversationConnection(
            credential: { _ in "test" },
            connect: { _ in
                let socket = ConversationSocket()
                if sockets.isEmpty { socket.events = [["type": "error", "error": ["code": "rate_limit_exceeded"]]] }
                sockets.append(socket)
                return socket.channel
            })
        defer { connection.reset() }
        let service = RealtimeService(reuseConnection: true)
        let request = ConversationRequest(history: [], text: "Hello", conversationID: UUID())
        do {
            _ = try await connection.reply(service: service, input: request)
            XCTFail("Expected provider failure")
        } catch {}
        XCTAssertEqual(sockets.count, 1, "A failed turn must never be automatically resent")
        _ = try await connection.reply(service: service, input: request)
        XCTAssertEqual(sockets.count, 2)
    }
    @MainActor func testClosedIdleSocketReconnectsBeforeAnyPartOfTheNextTurnIsSent() async throws {
        var sockets: [ConversationSocket] = []
        let connection = RealtimeConversationConnection(
            credential: { _ in "test" },
            connect: { _ in
                let socket = ConversationSocket()
                sockets.append(socket)
                return socket.channel
            })
        defer { connection.reset() }
        let service = RealtimeService(reuseConnection: true)
        let id = UUID()
        _ = try await connection.reply(
            service: service, input: ConversationRequest(history: [], text: "First", conversationID: id))
        let firstTurnEvents = sockets[0].sent.count
        sockets[0].closed = true
        _ = try await connection.reply(
            service: service, input: ConversationRequest(history: [], text: "Second", conversationID: id))
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(sockets[0].sent.count, firstTurnEvents, "No part of the new turn may enter the dead socket")
        XCTAssertEqual(sockets[1].sent.filter { $0["type"] as? String == "response.create" }.count, 1)
    }
    @MainActor func testHealthyIdleSocketReusesSessionWithoutWaitingForAPong() async throws {
        var sockets: [ConversationSocket] = []
        let connection = RealtimeConversationConnection(
            credential: { _ in "test" },
            connect: { _ in
                let socket = ConversationSocket()
                sockets.append(socket)
                return socket.channel
            })
        defer { connection.reset() }
        let service = RealtimeService(reuseConnection: true)
        let id = UUID()
        _ = try await connection.reply(
            service: service, input: ConversationRequest(history: [], text: "First", conversationID: id))
        sockets[0].pingFails = true
        let timing = VoiceReplyTiming()
        _ = try await connection.reply(
            service: service,
            input: ConversationRequest(history: [], text: "Second", conversationID: id, voiceTiming: timing))
        XCTAssertEqual(sockets.count, 1, "An unavailable pong must not force a reconnect")
        XCTAssertEqual(sockets[0].pingCount, 0)
        XCTAssertNotNil(timing.elapsedMilliseconds(at: .sessionProbeReady))
        XCTAssertNil(timing.elapsedMilliseconds(at: .connectionNew))
        XCTAssertEqual(
            sockets[0].sent.filter { $0["type"] as? String == "session.update" }.count, 2,
            "The probe configures the next turn; do not repeat that round trip")
    }
    @MainActor func testFailureAfterSuccessfulProbeDoesNotResubmitTheTurn() async throws {
        var sockets: [ConversationSocket] = []
        let connection = RealtimeConversationConnection(
            credential: { _ in "test" },
            connect: { _ in
                let socket = ConversationSocket()
                sockets.append(socket)
                return socket.channel
            })
        defer { connection.reset() }
        let service = RealtimeService(reuseConnection: true)
        let id = UUID()
        _ = try await connection.reply(
            service: service, input: ConversationRequest(history: [], text: "First", conversationID: id))
        sockets[0].failResponse = true
        do {
            _ = try await connection.reply(
                service: service, input: ConversationRequest(history: [], text: "Second", conversationID: id))
            XCTFail("Expected provider failure")
        } catch {}
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(
            sockets[0].sent.filter { $0["type"] as? String == "response.create" }.count, 2,
            "Each submitted turn is requested once")
    }
    @MainActor func testProviderRejectingSessionProbeDoesNotReconnectOrSendInput() async throws {
        var sockets: [ConversationSocket] = []
        let connection = RealtimeConversationConnection(
            credential: { _ in "test" },
            connect: { _ in
                let socket = ConversationSocket()
                sockets.append(socket)
                return socket.channel
            })
        defer { connection.reset() }
        let service = RealtimeService(reuseConnection: true)
        let id = UUID()
        _ = try await connection.reply(
            service: service, input: ConversationRequest(history: [], text: "First", conversationID: id))
        let firstCount = sockets[0].sent.count
        sockets[0].failSession = true
        do {
            _ = try await connection.reply(
                service: service, input: ConversationRequest(history: [], text: "Second", conversationID: id))
            XCTFail("Expected rejected probe")
        } catch {}
        XCTAssertEqual(sockets.count, 1, "Provider rejections must not trigger a retry")
        XCTAssertEqual(sockets[0].sent.dropFirst(firstCount).compactMap { $0["type"] as? String }, ["session.update"])
    }
}
