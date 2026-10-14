import Foundation
import MochiCore
import MochiKernel

/// One explicit user-started microphone session, independent of individual reply epochs.
@MainActor final class HandsFreeConversation {
    private weak var app: AppModel?
    let conversationID: UUID
    private let device: any HandsFreeAudioDevice
    private let detector = SpeechTurnDetector()
    private var inputTask: Task<Void, Never>?
    private let previousPlayerFactory: (@escaping @MainActor (Bool) -> Void) throws -> any StreamingPlaybackPlayer
    private var replyID: UUID?
    private var stopped = false
    init(app: AppModel, conversationID: UUID, device: any HandsFreeAudioDevice) {
        self.app = app
        self.conversationID = conversationID
        self.device = device
        previousPlayerFactory = app.audio.makeStream
    }
    private var current: Bool { !stopped && app?.handsFree === self && app?.selectedID == conversationID }
    func start() throws {
        let input = try device.start()
        app?.audio.makeStream = { [weak self] finished in
            guard let self, self.current else { throw CancellationError() }
            return try self.device.makePlayer(finished: finished)
        }
        inputTask = Task { [weak self] in
            do {
                for try await pcm in input {
                    guard let self, self.current, !Task.isCancelled else { return }
                    self.consume(pcm)
                }
                if let self, self.current {
                    self.failed(AppFailure("The microphone stopped. Start continuous conversation again."))
                }
            } catch {
                guard let self, self.current, !Task.isCancelled else { return }
                self.failed(error)
            }
        }
        listening()
    }
    func consume(_ pcm: Data) {
        guard current, let app else { return }
        let events = detector.accept(pcm)
        app.recordingLevel = max(-80, detector.levelDB)
        app.handsFreeSpeechDetected = detector.speaking
        for event in events {
            guard current else { return }
            switch event {
            case .started:
                // The reply task is cancelled before a later audio callback can schedule more playback.
                if let replyID, let ci = app.library.conversations.firstIndex(where: { $0.id == conversationID }),
                    let mi = app.library.conversations[ci].messages.firstIndex(where: { $0.id == replyID })
                {
                    app.library.conversations[ci].messages[mi].interrupted = true
                    if !app.save() {
                        failed(AppFailure("The interrupted reply could not be saved."))
                        return
                    }
                }
                replyID = nil
                _ = app.cancelTurn(preservingHandsFree: true)
                _ = app.turn.begin(.recording)
            case .ended(let audio):
                do {
                    let name = "recording-\(UUID().uuidString).wav"
                    try PCM.wav(audio).write(to: app.store.root.appendingPathComponent(name), options: .atomic)
                    if let ci = app.library.conversations.firstIndex(where: { $0.id == conversationID }) {
                        app.library.conversations[ci].voiceIntroduced = true
                    }
                    app.recordingLevel = -80
                    app.requestReply(
                        history: app.conversation?.messages ?? [], text: "", pcm: audio,
                        audioFile: name, conversationID: conversationID)
                } catch { failed(error) }
            }
        }
    }
    func replySaved() {
        guard current else { return }
        replyID = app?.conversation?.messages.last.flatMap { $0.role == "assistant" ? $0.id : nil }
    }
    func listening() {
        guard current, let app else { return }
        replyID = nil
        app.speaking = false
        app.recordingSeconds = 0
        app.recordingWarning = nil
        _ = app.turn.begin(.recording)
    }
    private func failed(_ error: Error) {
        guard current, let app else { return }
        app.stop()
        app.error = AppFailure.message(
            for: error,
            fallback: "Continuous conversation stopped. Check your microphone and connection, then start again.")
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        inputTask?.cancel()
        inputTask = nil
        device.stop()
        app?.audio.makeStream = previousPlayerFactory
    }
}

extension AppModel {
    var handsFreeActive: Bool { handsFree != nil }
    func startHandsFreeConversation() {
        guard !busy, !practice, writableConversation, libraryReadable, let id = selectedID else { return }
        handsFreeStarting = true
        let token = turn.begin(.requestingPermission)
        error = nil
        task = Task { [weak self] in
            guard let self, !Task.isCancelled, turn.epoch == token else { return }
            let allowed = await media.permission()
            guard !Task.isCancelled, turn.epoch == token else { return }
            guard selectedID == id, !practice, writableConversation, libraryReadable, continuousConversation else {
                handsFreeStarting = false
                _ = turn.finish(token)
                task = nil
                return
            }
            do {
                guard allowed else {
                    throw AppFailure(
                        "Microphone access is off. Enable Mochi in System Settings → Privacy & Security → Microphone.")
                }
                speech.resetConversation()
                let session = HandsFreeConversation(app: self, conversationID: id, device: try makeHandsFreeAudio())
                handsFree = session
                handsFreeStarting = false
                do { try session.start() } catch {
                    endHandsFreeConversation()
                    throw error
                }
                task = nil
            } catch { fail(error, token: token, context: "Start continuous conversation") }
        }
    }
    func endHandsFreeConversation() {
        handsFreeStarting = false
        handsFreeSpeechDetected = false
        let session = handsFree
        handsFree = nil
        session?.stop()
    }
}
