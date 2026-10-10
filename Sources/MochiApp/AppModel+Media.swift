import AppKit
import MochiCore
import MochiKernel

/// Playback and recording, arbitrated by the shared turn machine.
extension AppModel {
    var microphoneLabel: String {
        if turn.activity == .recording { return "Finish Recording" }
        if greetingActive { return "Skip Greeting and Start Recording" }
        return conversation?.voiceIntroduced == true ? "Record Voice Message" : "Start Voice Conversation"
    }
    func cancelRecording() {
        let url = media.stopRecording()
        cancelHelpWork()
        removeUnreferencedRecording(url?.lastPathComponent)
    }
    func togglePlayback(_ file: String, mochi: Bool = false) {
        if playbackFile == file && turn.activity == .playing {
            audio.togglePause()
            return
        }
        play(file, mochi: mochi)
    }
    func seekPlayback(_ file: String, to seconds: Double, mochi: Bool = false) {
        guard seconds.isFinite else { return }
        if playbackFile != file { play(file, mochi: mochi) }
        guard playbackFile == file else { return }
        audio.seek(to: seconds)
    }
    func play(
        _ file: String, mochi: Bool = false, afterPlayback: (() -> Void)? = nil,
        afterPlaybackFailure: (() -> Void)? = nil
    ) {
        guard !busy || turn.activity == .playing else { return }
        if afterPlayback == nil { greetingActive = false }
        audio.stop()
        playbackFile = nil
        let token = turn.begin(.playing)
        speaking = mochi
        let finished: () -> Void = { [weak self] in
            guard let self, self.turn.epoch == token else { return }
            self.playbackFile = nil
            self.speaking = false
            _ = self.turn.finish(token)
        }
        do {
            try audio.play(
                url: store.root.appendingPathComponent(file), rate: slow && !mochi ? 0.8 : 1,
                failed: { [weak self] in
                    guard let self, self.turn.epoch == token else { return }
                    finished()
                    self.greetingActive = false
                    self.error = "This recording could not be played. Try another recording."
                    afterPlaybackFailure?()
                },
                completed: { [weak self] in
                    guard let self, self.turn.epoch == token else { return }
                    finished()
                    afterPlayback?()
                })
            playbackFile = file
        } catch {
            playbackFile = nil
            fail(error, token: token, context: "Play audio")
            afterPlaybackFailure?()
        }
    }
    func recordMeaning() {
        guard !isSavedPractice else {
            notice = "Open Help Me Say This from the conversation to record a new thought."
            return
        }
        beginRecording(forMeaning: true)
    }
    func toggleRecord() {
        guard practice || writableConversation else { return }
        beginRecording(forMeaning: false)
    }
    func beginRecording(forMeaning: Bool) {
        if turn.activity == .recording {
            finishRecording()
            return
        }
        guard !busy, libraryReadable else { return }
        recordingMeaning = forMeaning
        if practice && !recordingMeaning { ensureExpression() }
        let token = turn.begin(.requestingPermission)
        task = Task {
            let allowed = await media.permission()
            guard !Task.isCancelled, turn.epoch == token else { return }
            guard allowed else {
                recordingMeaning = false
                _ = turn.finish(token)
                error = "Microphone access is off. Enable Mochi in System Settings → Privacy & Security → Microphone."
                return
            }
            do {
                let file = store.root.appendingPathComponent("recording-\(UUID().uuidString).wav")
                try media.record(file)
                if !practice, let index = library.conversations.firstIndex(where: { $0.id == selectedID }) {
                    library.conversations[index].voiceIntroduced = true
                    save()
                }
                _ = turn.finish(token)
                _ = turn.startRecording()
                recordingSeconds = 0
                recordingWarning = nil
                startRecordingFeedback(token: turn.epoch)
            } catch { fail(error, token: token, context: "Start recording") }
        }
    }
    func updateRecordingFeedback(elapsed: Double, level: Float) {
        recordingSeconds = Int(max(0, min(60, elapsed.isFinite ? elapsed : 0)))
        recordingLevel = level.isFinite ? min(0, max(-80, level)) : -80
        recordingWarning =
            recordingSeconds >= 1 && recordingLevel < -48
            ? "Input is very quiet. Check your microphone or speak closer." : nil
    }
    func startRecordingFeedback(token: UUID) {
        recordingClock?.cancel()
        let started = recordingNow()
        recordingClock = Task {
            while !Task.isCancelled {
                do { try await recordingSleep(100_000_000) } catch { return }
                guard !Task.isCancelled, turn.epoch == token else { return }
                updateRecordingFeedback(elapsed: recordingNow().timeIntervalSince(started), level: media.meter())
                if recordingSeconds >= 60 {
                    finishRecording()
                    return
                }
                if !media.recordingActive() {
                    recordingInterrupted()
                    return
                }
            }
        }
    }
    /// The microphone stopped mid-take. A partial take is discarded rather than sent as if complete.
    private func recordingInterrupted() {
        cancelRecording()
        error =
            "Recording stopped because the microphone disconnected or stopped responding. Check your microphone, then record again."
    }
    func finishRecording() {
        guard let url = media.stopRecording() else {
            stop()
            return
        }
        recordingClock?.cancel()
        recordingClock = nil
        turn.stop()
        recordingLevel = -80
        if recordingMeaning {
            recordingMeaning = false
            thoughtRecording = url.lastPathComponent
            if let samples = try? AudioFile.samples(url).samples {
                recordingWarning =
                    RecordingSignal(samples: samples).isQuiet
                    ? "This recording is very quiet. Listen before transcribing, or record it again." : nil
            }
            notice = "Your thought is recorded locally. Listen, then choose Transcribe."
            persistHelpDraft()
        } else if practice {
            runExclusive("Analyse practice attempt") { [weak self] job in
                guard let self else { return }
                let pitch = try await AudioFile.pitchInBackground(url)
                guard job.isCurrent() else { return }
                expression?.attempts.append(Attempt(file: url.lastPathComponent))
                attemptPitch = pitch
                saveExpression()
                job.finish()
                notice =
                    pitch.contains(where: { $0.hz != nil })
                    ? "Try comparing one phrase at a time. These contours are unscored."
                    : "No clear voiced pitch detected. Try speaking closer to the microphone."
            }
        } else if let id = selectedID {
            do {
                let pcm = try AudioFile.pcm(url)
                requestReply(
                    history: conversation?.messages ?? [], text: "", pcm: pcm, audioFile: url.lastPathComponent,
                    conversationID: id)
            } catch {
                MochiLog.failure(MochiLog.audio, "Read finished recording", error)
                self.error = AppFailure.message(
                    for: error, fallback: "This recording could not be read. Record your message again.")
            }
        }
    }
}
