import Foundation
import MochiCore
import MochiProviders

/// True inside an XCTest process. Live services must never run there: a test that forgets a fake
/// would otherwise reach the network or the microphone silently.
enum TestEnvironment {
    static let active = NSClassFromString("XCTestCase") != nil
    static func assertNotUnderTest(_ what: String) {
        precondition(!active, "\(what) must not be used in tests. Pass fakes to AppModel(speech:media:).")
    }
}

/// Everything AppModel sends to OpenAI. Each call receives the configured voice service.
struct SpeechServices {
    /// One conversation turn: text or speech in, a streamed reply and transcript out.
    var conversationReply: (RealtimeService, ConversationRequest, ReplyCallbacks) async throws -> Void
    /// A text-only reply, used for Help Me Say This and the connection check.
    var textReply: (RealtimeService, ConversationRequest) async throws -> String
    /// Spoken audio for exact text: (text, service, folder, regenerate).
    var referenceAudio: (String, RealtimeService, URL, Bool) async throws -> URL
    /// Transcribes a saved recording: (file, model).
    var transcribe: (URL, String) async throws -> String

    static var live: SpeechServices {
        TestEnvironment.assertNotUnderTest("SpeechServices.live")
        return SpeechServices(
            conversationReply: { service, request, callbacks in
                _ = try await service.reply(
                    request, onResponse: callbacks.response, onTranscription: callbacks.transcription,
                    onTool: callbacks.tool)
            },
            textReply: { service, request in try await service.reply(request).text },
            referenceAudio: { text, service, root, force in
                try await service.referenceAudio(text: text, root: root, force: force)
            },
            transcribe: { url, model in try await RealtimeService(model: model).transcribe(AudioFile.pcm(url)) })
    }
}

/// Microphone access. Playback goes through `AudioController.makePlayer`.
struct MediaServices {
    var permission: @MainActor () async -> Bool
    var record: @MainActor (URL) throws -> Void
    var stopRecording: @MainActor () -> URL?
    var meter: @MainActor () -> Float
    /// False when the microphone stopped delivering audio before the user finished.
    var recordingActive: @MainActor () -> Bool = { true }
    /// True when the last take ended because the microphone or recorder failed; still valid after `stopRecording`.
    var recordingInterrupted: @MainActor () -> Bool = { false }
    /// True once the recorder confirmed it stopped successfully at its own time limit; reported asynchronously.
    var recordingFinished: @MainActor () -> Bool = { false }

    @MainActor static func live(_ audio: AudioController) -> MediaServices {
        TestEnvironment.assertNotUnderTest("MediaServices.live")
        return MediaServices(
            permission: { await audio.permission() },
            record: { try audio.record(to: $0) },
            stopRecording: { audio.stopRecording() },
            meter: { audio.meter },
            recordingActive: { audio.isRecording },
            recordingInterrupted: { audio.recordingInterrupted },
            recordingFinished: { audio.recordingFinished })
    }
}

struct ReplyCallbacks {
    let response: @MainActor (RealtimeAccumulator) throws -> Void
    let transcription: @MainActor (RealtimeAccumulator) -> Void
    let tool: @MainActor (String, [String: Any], String) throws -> [String: Any]
}
