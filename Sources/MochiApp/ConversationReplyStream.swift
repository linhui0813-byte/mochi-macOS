import Foundation

/// One reply's live playback. Saving the final reply must never replay audio that was already streamed.
@MainActor final class ConversationReplyStream {
    private weak var app: AppModel?
    private let token: UUID
    private let enabled: Bool
    private var started = false
    private var failed = false
    private var drained = false
    private var responseFinished = false
    private var settled = false
    private var afterPlayback: (() -> Void)?
    private var file: String?
    init(app: AppModel, token: UUID, enabled: Bool) {
        self.app = app
        self.token = token
        self.enabled = enabled
    }
    func append(_ data: Data) {
        guard enabled, !data.isEmpty, !failed, !Task.isCancelled, let app, app.turn.epoch == token else { return }
        do {
            if !started {
                try app.audio.startStreaming(
                    failed: { self.playbackFailed() },
                    completed: {
                        self.drained = true
                        self.finishIfReady()
                    })
                started = true
                app.speaking = true
            }
            try app.audio.appendStreaming(data)
        } catch {
            playbackFailed()
        }
    }
    /// Returns true when live playback owns completion; false uses the normal saved-file player.
    func finish(file: String?) -> Bool {
        guard started, let app, app.turn.epoch == token else { return false }
        self.file = file
        responseFinished = true
        afterPlayback = app.deferredToolAction
        app.deferredToolAction = nil
        if !failed {
            app.playbackFile = file
            app.turn.transition(token, to: .playing)
            do { try app.audio.finishStreaming() } catch { playbackFailed() }
        }
        finishIfReady()
        return true
    }
    private func playbackFailed() {
        guard let app, app.turn.epoch == token else { return }
        failed = true
        app.audio.stop()
        app.speaking = false
        finishIfReady()
    }
    private func finishIfReady() {
        guard !settled, responseFinished, drained || failed, let app, app.turn.epoch == token else { return }
        settled = true
        app.playbackFile = nil
        app.speaking = false
        _ = app.turn.finish(token)
        if failed, file != nil {
            app.notice = String(localized: "Live playback stopped. The reply is saved; press Play to hear it again.")
        }
        let action = afterPlayback
        afterPlayback = nil
        action?()
    }
}
