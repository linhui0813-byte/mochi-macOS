import AppKit
import MochiCore
import MochiKernel

/// Help Me Say This: from a thought to English, an example to listen to, and practice attempts.
extension AppModel {
    func openExpressions() {
        closeConversationSearch()
        cancelHelpWork()
        leavePractice()
        expression = nil
        showExpressions = true
    }
    func startHelp() {
        guard writableConversation else { return }
        let cancelledReply = !practice && task != nil && turn.activity == .generating
        cancelHelpWork()
        error = nil
        turn.pause()
        showExpressions = false
        isSavedPractice = false
        let saved = conversation?.helpDraft
        restoringHelp = true
        meaning = saved?.meaning ?? draft
        english = saved?.english ?? ""
        thoughtRecording = saved?.recording
        helpClarification = saved?.clarification
        recognizedThought = saved?.transcriptReview
        expression = saved?.expressionID.flatMap { id in library.expressions.first(where: { $0.id == id }) }
        restoringHelp = false
        helpStage = english.isEmpty || recognizedThought != nil ? .thought : .english
        referencePitch = []
        attemptPitch = []
        notice =
            cancelledReply
            ? String(localized: "Your pending reply was cancelled. You can retry it when you return.") : nil
        recordingWarning = nil
        if let thoughtRecording { warnIfQuiet(thoughtRecording) }
        persistHelpDraft()
    }
    /// Decodes the restored thought off the main actor; the warning applies only if that recording is still current.
    private func warnIfQuiet(_ recording: String) {
        let url = store.root.appendingPathComponent(recording)
        Task { [weak self] in
            let quiet = await Task.detached(priority: .utility) { () -> Bool in
                guard let samples = try? AudioFile.samples(url).samples else { return false }
                return RecordingSignal(samples: samples).isQuiet
            }.value
            guard let self, quiet, thoughtRecording == recording, turn.activity != .recording else { return }
            recordingWarning = String(
                localized: "This recording is very quiet. Listen before transcribing, or record it again.")
        }
    }
    /// Typing in an existing draft is written after a pause; every other change is written at once,
    /// because callers such as recording replacement delete files only after the new state is saved.
    @discardableResult func persistHelpDraft(typing: Bool = false) -> Bool {
        guard case (let ci, let draft)? = currentHelpDraft() else { return false }
        if typing, library.conversations[ci].helpDraft != nil {
            updateLibraryQuietly { $0.conversations[ci].helpDraft = draft }
            scheduleSave()
            return true
        }
        library.conversations[ci].helpDraft = draft
        return save()
    }
    /// Puts the help draft into the library without writing it, for a caller that saves once afterwards.
    func stageHelpDraft() {
        guard case (let ci, let draft)? = currentHelpDraft() else { return }
        library.conversations[ci].helpDraft = draft
    }
    /// The help draft to keep and its conversation, or nil when there is none.
    private func currentHelpDraft() -> (Int, HelpDraft)? {
        guard !restoringHelp, !isSavedPractice, practice, writableConversation,
            let ci = library.conversations.firstIndex(where: { $0.id == selectedID })
        else { return nil }
        var draft = HelpDraft(
            meaning: meaning, english: english, recording: thoughtRecording, expressionID: expression?.id)
        draft.clarification = helpClarification
        draft.transcriptReview = recognizedThought
        return (ci, draft)
    }
    func editThought() {
        helpStage = .thought
        error = nil
    }
    func beginPractice() {
        guard !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ensureExpression()
        helpStage = .practice
        persistHelpDraft()
    }
    func reviewEnglish() { if !english.isEmpty { helpStage = .english } }
    func transcribeThought() {
        guard !busy, let thoughtRecording else { return }
        let transcribe = speech.transcribe
        let model = settings.effectiveModelName
        let url = store.root.appendingPathComponent(thoughtRecording)
        runExclusive("Transcribe thought", progress: "Transcribing your thought…") { [weak self] job in
            guard let self else { return }
            let text = try await transcribe(url, model)
            guard job.isCurrent() else { return }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                throw AppFailure("No clear speech was recognized. Your thought is saved; listen or record again.")
            }
            if meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                meaning = clean
            } else {
                recognizedThought = clean
            }
            job.finish()
            notice = String(localized: "Check the recognized thought before finding the English.")
        }
    }
    func useRecognizedThought(replace: Bool) {
        guard !busy, let recognizedThought else { return }
        meaning =
            replace || meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? recognizedThought : meaning + "\n" + recognizedThought
        self.recognizedThought = nil
        notice = String(localized: "Check your thought before finding the English.")
    }
    func discardThoughtRecording() {
        thoughtRecording = nil
        recordingWarning = nil
    }
    func translate() { findEnglish(alternative: false) }
    func tryAnotherWording() { findEnglish(alternative: true) }
    private func findEnglish(alternative: Bool) {
        let input = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !busy, let id = selectedID else { return }
        let history = conversation?.messages ?? []
        let service = settings.conversationService()
        let requestText =
            alternative && !english.isEmpty
            ? "Intended thought: \(input)\nPrevious English wording: \(english)\nOffer a different natural wording with exactly the same meaning."
            : input
        let textReply = speech.textReply
        runExclusive("Find the English", progress: "Finding the English…") { [weak self] job in
            guard let self else { return }
            let result = try await textReply(
                service, ConversationRequest(history: history, text: requestText, help: true))
            guard job.isCurrent() else { return }
            let suggestion = try HelpSuggestion.parse(result)
            if suggestion.kind == .clarification {
                helpClarification = suggestion.text
                helpStage = .thought
            } else {
                english = suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines)
                expression = PracticeExpression(conversationID: id, meaning: input, english: english)
                referencePitch = []
                attemptPitch = []
                helpClarification = nil
                helpStage = .english
            }
            helpProgress = nil
            persistHelpDraft()
        }
    }
    func editEnglish(_ text: String) {
        english = text
        if expression?.english != text {
            expression = nil
            referencePitch = []
            attemptPitch = []
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && helpStage == .thought {
            helpStage = .english
        }
        persistHelpDraft()
    }
    func ensureExpression() {
        guard let id = selectedID else { return }
        if expression == nil {
            expression = PracticeExpression(
                conversationID: id, meaning: meaning, english: english.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    @discardableResult func saveExpression() -> Bool {
        ensureExpression()
        // The thought can be edited after the expression was created; save what the user now sees.
        let thought = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = expression, current.meaning != thought { expression?.meaning = thought }
        guard let expression, !expression.english.isEmpty else { return false }
        if let index = library.expressions.firstIndex(where: { $0.id == expression.id }) {
            library.expressions[index] = expression
        } else {
            library.expressions.insert(expression, at: 0)
        }
        persistHelpDraft()
        return save()
    }
    func render(force: Bool = false) {
        guard !busy, !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ensureExpression()

        let text = english
        let label = settings.practiceVoiceLabel
        let root = store.root
        let referenceAudio = speech.referenceAudio
        let service = settings.practiceService()
        runExclusive("Create example", progress: "Creating your example…") { [weak self] job in
            guard let self else { return }
            let url = try await referenceAudio(text, service, root, force)
            let pitch = try await AudioFile.pitchInBackground(url)
            guard job.isCurrent() else { return }
            expression?.reference = url.lastPathComponent
            expression?.referenceKind = label
            referencePitch = pitch
            saveExpression()
            job.finish()
            notice = String(localized: "Your reference is ready. Listen, then try saying it yourself.")
        }
    }

    func previewBuiltIn(_ voice: String, options: OpenAIVoiceOptions? = nil) {
        // Previews are cached beside the library; an unreadable library folder must stay untouched.
        guard !busy, libraryReadable else { return }
        let service = settings.practiceService(voice: voice, options: options)
        let root = store.root
        let referenceAudio = speech.referenceAudio
        previewEpoch = runExclusive("Preview voice") { [weak self] job in
            guard let self else { return }
            let url = try await referenceAudio(ReferenceSpeech.preview, service, root, false)
            guard job.isCurrent() else { return }
            job.finish()
            play(url.lastPathComponent)
            if playbackFile == url.lastPathComponent { previewEpoch = turn.epoch }
        }
    }
    var canImportReference: Bool { !busy && !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func importReference() {
        guard canImportReference, let source = chooseFile(.importReference) else { return }
        importReference(from: source)
    }
    func importReference(from source: URL) {
        // An expression without English cannot be saved, so the copied file would be left unreferenced.
        guard canImportReference else { return }
        ensureExpression()
        runExclusive("Import reference") { [weak self] job in
            guard let self else { return }
            let pitch = try await AudioFile.pitchInBackground(source)
            guard job.isCurrent() else { return }
            let name = "import-\(UUID().uuidString).\(source.pathExtension)"
            try FileManager.default.copyItem(at: source, to: store.root.appendingPathComponent(name))
            expression?.reference = name
            expression?.referenceKind = "Imported reference"
            referencePitch = pitch
            saveExpression()
        }
    }
    func resume() {
        cancelHelpWork()
        let completed = !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && saveExpression()
        if completed, !isSavedPractice, let ci = library.conversations.firstIndex(where: { $0.id == selectedID }) {
            let saved = library.conversations[ci].helpDraft
            library.conversations[ci].helpDraft = nil
            if save() {
                restoringHelp = true
                thoughtRecording = nil
                recognizedThought = nil
                restoringHelp = false
                removeUnreferencedRecording(saved?.recording)
            } else {
                library.conversations[ci].helpDraft = saved
            }
        }
        leavePractice()
        expression = nil
        notice =
            completed
            ? String(localized: "Saved to My Expressions. Say the thought in your own words when you're ready.")
            : String(localized: "Help draft saved.")
    }
    func openExpression(_ opened: PracticeExpression) {
        var item = opened
        var sourceID = item.conversationID
        if !library.conversations.contains(where: { $0.id == sourceID && !$0.isDeleted && !$0.archived }) {
            var candidate = library
            let chat = Conversation(title: "Practice: " + String(item.english.prefix(42)))
            candidate.conversations.insert(chat, at: 0)
            candidate.selectedConversationID = chat.id
            // Point the expression at its new home, so reopening it does not create yet another conversation.
            item.conversationID = chat.id
            if let index = candidate.expressions.firstIndex(where: { $0.id == item.id }) {
                candidate.expressions[index].conversationID = chat.id
            }
            guard commitHistory(candidate) else { return }
            sourceID = chat.id
        }
        if sourceID == selectedID { cancelHelpWork() } else { stop() }
        leavePractice()
        isSavedPractice = true
        selectedID = sourceID
        historyScope = .active
        search = ""
        draft = conversation?.draft ?? ""
        showExpressions = false
        turn.pause()
        restoringHelp = true
        expression = item
        english = item.english
        meaning = item.meaning
        thoughtRecording = nil
        recognizedThought = nil
        restoringHelp = false
        helpStage = .practice
        referencePitch = []
        attemptPitch = []
        let root = store.root
        let reference = item.reference
        let attempt = item.attempts.last?.file
        runExclusive("Open saved expression") { [weak self] job in
            guard let self else { return }
            // Each contour is analysed on its own, so one unreadable file does not hide the other.
            var failure: Error?
            if let name = reference {
                do {
                    let points = try await AudioFile.pitchInBackground(root.appendingPathComponent(name))
                    guard job.isCurrent() else { return }
                    referencePitch = points
                } catch {
                    guard job.isCurrent() else { return }
                    failure = error
                }
            }
            if let name = attempt {
                do {
                    let points = try await AudioFile.pitchInBackground(root.appendingPathComponent(name))
                    guard job.isCurrent() else { return }
                    attemptPitch = points
                } catch {
                    guard job.isCurrent() else { return }
                    failure = failure ?? error
                }
            }
            if let failure { throw failure }
        }
    }
}
