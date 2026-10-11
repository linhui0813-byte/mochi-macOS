import AppKit
import MochiCore
import MochiKernel
import MochiProviders

/// The conversation itself: sending text and voice, replies, transcription and the spoken greeting.
extension AppModel {
    /// False when the conversation is gone or the library could not be saved; the save failure is already reported.
    @discardableResult func append(_ message: Message, to id: UUID) -> Bool {
        guard let i = library.conversations.firstIndex(where: { $0.id == id }) else { return false }
        if !library.conversations[i].customTitle
            && !library.conversations[i].messages.contains(where: { $0.role == "user" }) && message.role == "user"
            && !message.text.isEmpty
        {
            library.conversations[i].title = String(message.text.prefix(42))
        }
        library.conversations[i].messages.append(message)
        return save()
    }
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, !practice, writableConversation, libraryReadable, let id = selectedID else {
            return
        }
        if conversation?.characterNameNeedsReview == true {
            error = String(
                localized: "Review the character name in Conversation Instructions before sending. Your draft is kept.")
            return
        }
        notice = nil
        let history = conversation?.messages ?? []
        error = nil
        let typed = draft
        let before = library.conversations.first { $0.id == id }
        // Cleared first, so the save that writes the message also writes the empty composer.
        draft = ""
        guard append(Message(role: "user", text: text), to: id) else {
            // Nothing is sent: the draft returns to the composer and the unsaved message leaves memory,
            // so memory never holds a message the disk lacks. The save failure is already reported.
            if let before, let i = library.conversations.firstIndex(where: { $0.id == id }) {
                library.conversations[i] = before
            }
            draft = typed
            return
        }
        requestReply(history: history, text: text, pcm: nil, audioFile: nil, conversationID: id)
    }
    var canRetry: Bool {
        guard writableConversation, !busy, !practice, let last = conversation?.messages.last, last.role == "user" else {
            return false
        }
        return !transcribingMessageIDs.contains(last.id)
    }
    func retryReply() {
        guard canRetry, let chat = conversation, let last = chat.messages.last else { return }
        if chat.characterNameNeedsReview {
            error = String(localized: "Review the character name in Conversation Instructions before retrying.")
            return
        }
        do {
            let pcm =
                try last.contextText == nil
                ? last.audio.map { try AudioFile.pcm(store.root.appendingPathComponent($0)) } : nil
            requestReply(
                history: Array(chat.messages.dropLast()), text: last.text, pcm: pcm, audioFile: last.audio,
                conversationID: chat.id, existingUserID: last.id)
        } catch {
            self.error = String(localized: "The saved recording could not be read. Record a new message to continue.")
        }
    }
    func requestReply(
        history: [Message], text: String, pcm: Data?, audioFile: String?, conversationID: UUID,
        existingUserID: UUID? = nil
    ) {
        if let existingUserID, transcribingMessageIDs.contains(existingUserID) { return }
        // Cleared first, so a failure to save the voice message below stays visible.
        error = nil
        var userID = existingUserID
        if pcm != nil && userID == nil {
            var message = Message(role: "user", text: "", audio: audioFile)
            message.transcriptionState = .pending
            userID = message.id
            append(message, to: conversationID)
        }
        let operationID =
            userID ?? library.conversations.first(where: { $0.id == conversationID })?.messages.last?.id ?? UUID()
        var requestID = UUID()
        if let userID, pcm != nil {
            requestID = transcripts.begin(userID)
            updateTranscript(userID, chatID: conversationID, text: nil, state: .pending, error: nil)
        }
        let token = turn.begin(.generating)
        let chat = library.conversations.first { $0.id == conversationID }
        let instructions = ConversationInstructions.bounded(chat?.instructions ?? "")
        let preferences = chat?.preferences ?? ConversationPreferences()
        let characterName = chat?.characterName
        let speakerName = chat?.displayCharacterName ?? "Mochi"
        let service = settings.conversationService(speed: preferences.speed)
        let voiceID = pcm == nil ? nil : userID
        let reply = speech.conversationReply
        let operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if turn.epoch == token { task = nil }
                if let voiceID, transcripts.isCurrent(voiceID, requestID) {
                    interruptPendingTranscript(voiceID, chatID: conversationID)
                    transcripts.finish(voiceID, requestID)
                }
            }
            do {
                let callbacks = ReplyCallbacks(
                    response: { [weak self] reply in
                        guard let self, !Task.isCancelled, turn.epoch == token else { return }
                        task = nil
                        let filename = saveReply(reply, conversationID: conversationID, speakerName: speakerName)
                        _ = turn.finish(token)
                        if reply.truncated {
                            notice =
                                "\(speakerName)’s reply reached its length limit and was cut short. Ask a follow-up to continue."
                        }
                        playReplyThenDeferredAction(filename)
                    },
                    transcription: { [weak self] reply in
                        guard let self, !Task.isCancelled, let voiceID, transcripts.isCurrent(voiceID, requestID) else {
                            return
                        }
                        updateTranscript(
                            voiceID, chatID: conversationID,
                            text: reply.inputTranscript.isEmpty ? nil : reply.inputTranscript,
                            state: reply.transcriptionState, error: reply.transcriptionError)
                    },
                    tool: { [weak self] name, args, _ in
                        guard let self, !Task.isCancelled, self.turn.epoch == token, self.selectedID == conversationID
                        else { throw CancellationError() }
                        return try self.tools.executeVoice(name, arguments: args, operationID: operationID)
                    })
                let request = ConversationRequest(
                    history: history, text: text, pcm: pcm, spoken: audioFile != nil, instructions: instructions,
                    characterName: characterName, preferences: preferences)
                try await reply(service, request, callbacks)
            } catch {
                // The deferred block marks a still-pending transcript as interrupted.
                if turn.epoch == token { deferredToolAction = nil }
                fail(error, token: token, context: "Conversation reply")
            }
        }
        task = operation
        if let voiceID { transcripts.attach(operation, to: voiceID) }
    }
    /// Writes the reply's audio and appends the reply; returns the audio file when one was written.
    /// The reply text is kept even when its audio cannot be written. A failed library save is reported by `save()`
    /// and is not overwritten, so the error never claims an unsaved reply was saved.
    private func saveReply(_ reply: RealtimeAccumulator, conversationID: UUID, speakerName: String) -> String? {
        var filename: String?
        var audioFailure: Error?
        if !reply.audio.isEmpty {
            let name = "reply-\(UUID().uuidString).wav"
            do {
                try writeReplyAudio(PCM.wav(reply.audio), store.root.appendingPathComponent(name))
                filename = name
            } catch { audioFailure = error }
        }
        var appended = true
        if filename != nil || !reply.text.isEmpty {
            appended = append(
                Message(role: "assistant", text: reply.text, audio: filename, speakerName: speakerName),
                to: conversationID)
        }
        guard let audioFailure, appended else { return filename }
        if reply.text.isEmpty {
            // An audio-only reply has nothing left to save once its audio is lost.
            error = persistenceMessage(
                audioFailure, action: "Save reply audio",
                fallback:
                    "\(speakerName)’s reply could not be saved because its audio file could not be written. Retry the reply.",
                diskFull:
                    "\(speakerName)’s reply could not be saved because the disk is full. Free some space, then retry the reply."
            )
        } else {
            error = persistenceMessage(
                audioFailure, action: "Save reply audio",
                fallback:
                    "\(speakerName)’s reply was saved without its audio because the audio file could not be written.",
                diskFull:
                    "\(speakerName)’s reply was saved without its audio because the disk is full. Free some space before the next reply."
            )
        }
        return filename
    }
    /// Plays the reply, then runs any tool action that waited for it.
    private func playReplyThenDeferredAction(_ filename: String?) {
        let action = deferredToolAction
        deferredToolAction = nil
        guard let filename else {
            action?()
            return
        }
        if let playReply {
            playReply(filename)
            action?()
        } else if let action {
            play(filename, mochi: true, afterPlayback: action, afterPlaybackFailure: action)
        } else {
            play(filename, mochi: true)
        }
    }
    private func interruptPendingTranscript(_ messageID: UUID, chatID: UUID) {
        guard
            library.conversations.first(where: { $0.id == chatID })?.messages.first(where: { $0.id == messageID })?
                .transcriptionState == .pending
        else { return }
        updateTranscript(
            messageID, chatID: chatID, text: nil, state: .interrupted,
            error: String(localized: "Transcription was interrupted. Your recording is saved."))
    }
    /// False when the message is gone or the library could not be saved; the save failure is already reported.
    @discardableResult private func updateTranscript(
        _ messageID: UUID, chatID: UUID, text: String?, state: TranscriptionState, error: String?
    ) -> Bool {
        guard let ci = library.conversations.firstIndex(where: { $0.id == chatID && !$0.isDeleted && !$0.archived }),
            let mi = library.conversations[ci].messages.firstIndex(where: { $0.id == messageID })
        else { return false }
        if let text { library.conversations[ci].messages[mi].text = text }
        library.conversations[ci].messages[mi].transcriptionState = state
        library.conversations[ci].messages[mi].transcriptionError = error
        if let text, !text.isEmpty, !library.conversations[ci].customTitle,
            library.conversations[ci].messages.first(where: { $0.role == "user" })?.id == messageID
        {
            library.conversations[ci].title = String(text.prefix(42))
        }
        return save()
    }
    func retryTranscription(_ messageID: UUID) {
        guard writableConversation, !busy,
            let chat = conversation,
            let message = chat.messages.first(where: { $0.id == messageID && $0.role == "user" }),
            let file = message.audio,
            !transcribingMessageIDs.contains(messageID)
        else { return }
        let jobID = transcripts.begin(messageID)
        let chatID = chat.id
        updateTranscript(messageID, chatID: chatID, text: nil, state: .pending, error: nil)
        let transcribe = speech.transcribe
        let model = settings.effectiveModelName
        let url = store.root.appendingPathComponent(file)
        let job = Task { [weak self] in
            guard let self else { return }
            defer { transcripts.finish(messageID, jobID) }
            do {
                let text = try await transcribe(url, model)
                guard !Task.isCancelled, transcripts.isCurrent(messageID, jobID) else { return }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else {
                    throw AppFailure(
                        "No clear speech was recognized. Your recording is saved; add text or record again.")
                }
                updateTranscript(messageID, chatID: chatID, text: clean, state: .completed, error: nil)
            } catch {
                guard !Task.isCancelled, transcripts.isCurrent(messageID, jobID) else { return }
                MochiLog.failure(MochiLog.network, "Retry transcription", error)
                updateTranscript(
                    messageID, chatID: chatID, text: nil, state: .failed,
                    error: AppFailure.message(
                        for: error,
                        fallback: "Transcription could not finish. Your recording is saved; retry or add text."))
            }
        }
        transcripts.attach(job, to: messageID)
    }
    func cancelTranscription(_ messageID: UUID) {
        transcripts.cancel(messageID)
        if let chatID = conversation?.id {
            updateTranscript(messageID, chatID: chatID, text: nil, state: .interrupted, error: nil)
        }
    }
    /// False when the transcript could not be saved; the failure is in `error`.
    @discardableResult func editTranscript(_ messageID: UUID, text: String) -> Bool {
        guard writableConversation, let chatID = conversation?.id else { return false }
        cancelTranscription(messageID)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return updateTranscript(
            messageID, chatID: chatID, text: clean, state: clean.isEmpty ? .failed : .completed, error: nil)
    }
    func toggleConversationVoice() {
        guard !practice, writableConversation, libraryReadable else { return }
        if turn.activity != .recording, !greetingActive, conversation?.characterNameNeedsReview == true {
            error = String(localized: "Review the character name in Conversation Instructions before recording.")
            return
        }
        if greetingActive {
            stop()
            beginRecording(forMeaning: false)
            return
        }
        guard !busy || turn.activity == .recording else { return }
        guard turn.activity != .recording, conversation?.voiceIntroduced == false, let id = selectedID else {
            beginRecording(forMeaning: false)
            return
        }
        let token = turn.begin(.requestingPermission)
        greetingActive = true
        error = nil
        let speakerName = conversation?.displayCharacterName ?? "Mochi"
        let service = settings.conversationService(speed: conversation?.preferences.speed)
        task = Task { [self] in
            do {
                let allowed: Bool
                allowed = await media.permission()
                guard !Task.isCancelled, turn.epoch == token else { return }
                guard allowed else {
                    throw AppFailure(
                        "Microphone access is off. Enable Mochi in System Settings → Privacy & Security → Microphone.")
                }
                // Each asynchronous stage is guarded by its epoch; Stop invalidates either stage.
                let generationToken = turn.begin(.generating)
                let recent = settings.recentGreetings
                let greeting = VoiceIdentity.namedGreeting(name: speakerName, excluding: recent)
                let text = greeting.text
                do {
                    let url = try await speech.referenceAudio(text, service, store.root, false)
                    guard !Task.isCancelled, turn.epoch == generationToken, selectedID == id,
                        !practice, writableConversation,
                        let index = library.conversations.firstIndex(where: { $0.id == id })
                    else { return }
                    library.conversations[index].messages.append(
                        Message(role: "assistant", text: text, audio: url.lastPathComponent, speakerName: speakerName))
                    library.conversations[index].voiceIntroduced = true
                    guard save() else {
                        library.conversations[index].messages.removeLast()
                        library.conversations[index].voiceIntroduced = false
                        greetingActive = false
                        _ = turn.finish(generationToken)
                        return
                    }
                    settings.recentGreetings = recent + [greeting.pattern]
                    task = nil
                    _ = turn.finish(generationToken)
                    play(
                        url.lastPathComponent, mochi: true,
                        afterPlayback: { [weak self] in
                            guard let self, self.greetingActive, self.selectedID == id, !self.practice,
                                self.writableConversation
                            else { return }
                            self.greetingActive = false
                            self.beginRecording(forMeaning: false)
                        })
                } catch { fail(error, token: generationToken, context: "Voice greeting") }
            } catch { fail(error, token: token, context: "Microphone permission") }
        }
    }
    func checkConnection() {
        guard !busy else { return }
        serviceStatus = String(localized: "Checking…")
        let service = settings.conversationService()
        let textReply = speech.textReply
        runExclusive(
            "Check connection", onFailure: { [weak self] in self?.serviceStatus = String(localized: "Not connected") },
            { [weak self] job in
                guard let self else { return }
                _ = try await textReply(
                    service, ConversationRequest(history: [], text: "Reply with the single word ready."))
                guard job.isCurrent() else { return }
                serviceStatus = String(localized: "Verified · text response received")
            })
    }
}
