import AppKit
import MochiCore
import MochiKernel
enum HelpStage { case thought, english, practice }
struct MessageDeletionUndo {
    let conversationID: UUID
    let message: Message
    let index: Int
}

@MainActor @Observable final class AppModel {
    /// Persistence: the library value, saving, recovery and transfers.
    let libraryController: LibraryController
    var library: Library {
        get { libraryController.library }
        _modify { yield &libraryController.library }
        set { libraryController.library = newValue }
    }
    var store: LibraryStore { libraryController.store }
    var libraryRevision: UUID { libraryController.revision }
    var libraryReadable: Bool { libraryController.readable }
    var canRestorePreviousLibrary: Bool { libraryController.canRestorePrevious }
    var startupProgress: String? { libraryController.startupProgress }
    var libraryTransfer: String? { libraryController.transfer }
    var dataFolder: URL { libraryController.dataFolder }
    var hasPendingSave: Bool { libraryController.hasPendingSave }
    var saveDelay: UInt64 {
        get { libraryController.saveDelay }
        set { libraryController.saveDelay = newValue }
    }
    func updateLibraryQuietly(_ change: (inout Library) -> Void) { libraryController.updateQuietly(change) }
    @ObservationIgnored var deferredToolAction: (() -> Void)?
    @ObservationIgnored var revealWorkspace: (() -> Void)?
    var templatePresentation: TemplatePresentation?
    var templateDraft: TemplateEditorDraft?
    @ObservationIgnored var templateReturnTo: TemplatePresentation?
    @ObservationIgnored var templateReturnDraft: TemplateEditorDraft?
    var retainedInstructionsDraft: ConversationSettingsDraft?
    var instructionsID: UUID?
    var externalControlEnabled: Bool {
        get { settings.externalControlEnabled }
        set { settings.externalControlEnabled = newValue; configureAutomation() }
    }
    /// The local control server and the caches that make tool calls safe to retry.
    let automation = AutomationController()
    @ObservationIgnored var allowDemoAutomation = false
    var selectedID: UUID? { didSet { if oldValue != selectedID { closeConversationSearch() } } }
    var conversationQuery = "" { didSet { refreshConversationMatches(reset:true) } }
    var conversationSearchOpen = false
    var conversationSearchFocusRequest = 0
    private(set) var conversationMatchID: UUID?
    private(set) var conversationMatchIDs: [UUID] = []
    private(set) var conversationMatchSet: Set<UUID> = []
    var conversationMatchIndex: Int { conversationMatchID.flatMap { conversationMatchIDs.firstIndex(of:$0) } ?? 0 }
    private func refreshConversationMatches(reset: Bool = false) {
        let previousIndex = conversationMatchIndex
        let ids = conversation?.matchingMessageIDs(conversationQuery) ?? []
        conversationMatchIDs = ids; conversationMatchSet = Set(ids)
        if reset || conversationMatchID == nil || !conversationMatchSet.contains(conversationMatchID!) {
            conversationMatchID = ids.isEmpty ? nil : ids[min(reset ? 0 : previousIndex,ids.count-1)]
        }
    }
    var canFindInConversation: Bool {
        !practice && renameID == nil && permanentDeleteIDs.isEmpty && (managerOpen || (!showExpressions && conversation != nil))
    }
    func findInConversation() {
        guard canFindInConversation else { return }
        if managerOpen { searchFocusRequest += 1 } else { openConversationSearch() }
    }
    func openConversationSearch() {
        guard conversation != nil, !showExpressions, !practice else { return }
        conversationSearchOpen = true; conversationSearchFocusRequest += 1
    }
    func closeConversationSearch() {
        conversationQuery = ""; conversationSearchOpen = false
    }
    func moveConversationMatch(_ direction: Int) {
        let count = conversationMatchIDs.count
        guard count > 0 else { conversationMatchID = nil; return }
        conversationMatchID = conversationMatchIDs[((conversationMatchIndex+direction)%count+count)%count]
    }
    var showExpressions = false
    var search = ""
    var searchOpen = false
    var searchFocusRequest = 0
    var historyScope: HistoryScope = .active
    var managerOpen = false
    var renameID: UUID?
    var permanentDeleteIDs: Set<UUID> = []
    var historyFeedback: String?
    var draft = "" {
        didSet {
            guard let i = library.conversations.firstIndex(where:{ $0.id == selectedID }), library.conversations[i].draft != draft else { return }
            updateLibraryQuietly { $0.conversations[i].draft = draft }
            scheduleSave()
        }
    }
    var meaning = "" { didSet { persistHelpDraft(typing:true) } }
    var english = "" { didSet { persistHelpDraft(typing:true) } }
    var helpStage: HelpStage = .thought
    var thoughtRecording: String? { didSet {
        guard !restoringHelp else { return }
        if isSavedPractice {
            if oldValue != thoughtRecording { removeUnreferencedRecording(oldValue) }
            return
        }
        if oldValue != thoughtRecording { recognizedThought = nil }
        if persistHelpDraft(), oldValue != thoughtRecording { removeUnreferencedRecording(oldValue) }
    } }
    var recognizedThought: String? { didSet { persistHelpDraft() } }
    var isSavedPractice = false
    var helpProgress: String?
    var helpClarification: String?
    var recordingLevel: Float = -80
    var recordingWarning: String?
    var transcripts = TranscriptJobs()
    var transcribingMessageIDs: Set<UUID> { transcripts.messageIDs }
    @ObservationIgnored var speech: SpeechServices
    @ObservationIgnored var media: MediaServices
    @ObservationIgnored var playReply: ((String) -> Void)?
    var greetingActive = false
    @ObservationIgnored var recordingNow: () -> Date = Date.init
    @ObservationIgnored var recordingSleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds:$0) }
    @ObservationIgnored var restoringHelp = false
    var expression: PracticeExpression?
    var turn = TurnMachine()
    var error: String?
    var notice: String? { didSet {
        if notice != "Message deleted." { finishMessageDeletion() }
        scheduleNoticeDismissal()
    } }
    var messageDeletionUndo: MessageDeletionUndo?
    @ObservationIgnored private var noticeTask: Task<Void,Never>?
    /// The timer that will clear the current notice, so a caller can wait for it to run.
    var pendingNoticeDismissal: Task<Void,Never>? { noticeTask }
    @ObservationIgnored private var noticeRevision = UUID()
    @ObservationIgnored var noticeSleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds:$0) }
    private func scheduleNoticeDismissal() {
        noticeTask?.cancel(); noticeTask = nil
        noticeRevision = UUID()
        guard notice != nil, !practice else { return }
        let revision = noticeRevision, sleep = noticeSleep
        let duration: UInt64 = messageDeletionUndo == nil ? 4_000_000_000 : 10_000_000_000
        noticeTask = Task { [weak self] in
            do { try await sleep(duration) } catch { return }
            guard !Task.isCancelled, let self, self.noticeRevision == revision else { return }
            self.notice = nil
        }
    }
    var referencePitch: [PitchPoint] = []
    var attemptPitch: [PitchPoint] = []
    var playbackFile: String?
    var speaking = false
    var slow = false
    var settingsOpen = false
    var recordingSeconds = 0
    var recordingMeaning = false
    var serviceStatus = "Not checked"
    let settings: PreferencesStore
    var settingsTab = "conversation"
    let audio: AudioController
    let demo: Bool
    @ObservationIgnored var task: Task<Void,Never>?
    /// The job that currently owns the turn, so callers can await its end after cancelling it.
    var currentTask: Task<Void,Never>? { task }
    @ObservationIgnored var recordingClock: Task<Void,Never>?
    @ObservationIgnored var chooseFile: @MainActor (PanelRequest) -> URL? = FilePanels.choose
    var conversation: Conversation? { library.conversations.first { $0.id == selectedID } }
    var writableConversation: Bool { conversation.map { !$0.archived && !$0.isDeleted } ?? false }
    var visibleChats: [Conversation] { library.history(in:historyScope,query:search) }
    var busy: Bool { turn.activity != .idle }
    var practice: Bool { turn.mode == .practice }
    var status: String {
        switch turn.activity {
        case .recording: if recordingMeaning { return "Recording your thought · finish to review" }; return practice ? "Recording your attempt · stays on this Mac" : "Recording · finish to send to \(displayCharacterName)"
        case .requestingPermission: return "Waiting for microphone permission"
        case .generating: if greetingActive { return "Preparing \(displayCharacterName)’s greeting…" }; return practice ? "Preparing your expression…" : "\(displayCharacterName) is thinking…"
        case .playing: if audio.paused { return "Playback paused" }; return speaking ? "\(displayCharacterName) is speaking" : "Playing your recording"
        case .idle: return practice ? "Conversation paused · microphone off" : "Ready when you are · microphone off"
        }
    }
    /// - Parameter applicationSupport: where the managed library lives when `libraryRoot` is nil; tests pass a temporary folder.
    init(demo: Bool = false, libraryRoot: URL? = nil, preferences: UserDefaults? = nil, speech: SpeechServices? = nil, media: MediaServices? = nil, applicationSupport: URL? = nil) {
        InstanceEvidence.record("model-created")
        assert(!TestEnvironment.active || preferences != nil, "Tests must give AppModel isolated preferences.")
        self.demo = demo
        let audio = AudioController()
        self.audio = audio; self.media = media ?? .live(audio); self.speech = speech ?? .live
        settings = PreferencesStore(preferences ?? (demo ? UserDefaults(suiteName:AppIdentity.bundleIdentifier + ".preview")! : .standard),
                                    importLegacy:!demo && libraryRoot == nil,allowExternalControl:!demo)
        let support = applicationSupport ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let managed = !demo && libraryRoot == nil
        let root = libraryRoot ?? (demo ? FileManager.default.temporaryDirectory.appendingPathComponent("mochi-preview-\(UUID().uuidString)") : support.appendingPathComponent(AppIdentity.name))
        libraryController = LibraryController(root:root,demo:demo)
        libraryController.selection = { [weak self] in self?.selectedID }
        libraryController.report = { [weak self] in self?.error = $0 }
        libraryController.onChange = { [weak self] in self?.refreshConversationMatches() }
        libraryController.open(managedIn:managed ? support : nil,isolated:libraryRoot != nil) { [weak self] in self?.libraryOpened() }
    }
    /// Selects where the user left off once the library is open, or failed to open.
    private func libraryOpened() {
        if demo { seedPreview() }
        else if library.conversations.isEmpty && libraryReadable { library.conversations = [Conversation()] }
        selectedID = library.selectedConversationID.flatMap { id in library.conversations.contains(where:{ $0.id == id }) ? id : nil } ?? library.history(in:.active).first?.id
        if let chat = conversation {
            historyScope = chat.isDeleted ? .deleted : chat.archived ? .archived : .active
            draft = chat.draft
        }
        // A first launch writes its library at once, so the data folder never holds only caches.
        if libraryReadable && !demo && !FileManager.default.fileExists(atPath:store.file.path) { save() }
    }
    @discardableResult func save() -> Bool { libraryController.save() }
    func scheduleSave() { libraryController.scheduleSave() }
    func persistenceMessage(_ error: Error, action: String, fallback: String, diskFull: String) -> String {
        LibraryController.persistenceMessage(error,action:action,fallback:fallback,diskFull:diskFull)
    }
    func restorePreviousLibrary() {
        do {
            try libraryController.restorePrevious()
            guard libraryReadable else { return }
            error = nil
            if library.conversations.isEmpty { library.conversations = [Conversation()] }
            selectedID = library.selectedConversationID.flatMap { id in library.conversations.contains(where:{ $0.id == id }) ? id : nil } ?? library.history(in:.active).first?.id
            historyScope = .active; draft = conversation?.draft ?? ""
            notice = "Restored the earlier copy of your library. The unreadable file was kept in the data folder."
        } catch {
            self.error = persistenceMessage(error,action:"Restore earlier library",fallback:"The earlier copy could not be restored. Nothing was changed.",diskFull:"The earlier copy could not be restored because the disk is full. Nothing was changed.")
        }
    }
    func revealDataFolder() {
        guard libraryController.revealDataFolder() else {
            error = "The data folder could not be opened. In Finder, choose Go → Go to Folder and enter ~/Library/Application Support."; return
        }
    }
    func stop() {
        deferredToolAction = nil
        greetingActive = false
        let unfinishedRecording = media.stopRecording()
        task?.cancel(); task = nil; recordingClock?.cancel(); recordingClock = nil
        transcripts.cancelAll()
        for ci in library.conversations.indices {
            for mi in library.conversations[ci].messages.indices where library.conversations[ci].messages[mi].transcriptionState == .pending {
                library.conversations[ci].messages[mi].transcriptionState = .interrupted
            }
        }
        helpProgress = nil; recordingLevel = -80
        audio.stop(); playbackFile = nil; speaking = false; recordingMeaning = false; turn.stop()
        persistHelpDraft(); save()
        removeUnreferencedRecording(unfinishedRecording?.lastPathComponent)
    }
    func cancelHelpWork() {
        deferredToolAction = nil
        greetingActive = false
        let recording = media.stopRecording()
        if !practice && task != nil && turn.activity == .generating { notice = "Your pending reply was cancelled. You can retry it when you return." }
        task?.cancel()
        task = nil; recordingClock?.cancel(); recordingClock = nil
        audio.stop(); playbackFile = nil; speaking = false; recordingMeaning = false; helpProgress = nil; recordingLevel = -80; turn.stop()
        persistHelpDraft(); removeUnreferencedRecording(recording?.lastPathComponent)
    }
    func leavePractice() {
        if isSavedPractice {
            let temporary = thoughtRecording
            restoringHelp = true; thoughtRecording = nil; recognizedThought = nil; restoringHelp = false
            removeUnreferencedRecording(temporary)
        }
        isSavedPractice = false; turn.resume()
    }
    /// A cancellable job that owns the turn. `isCurrent()` turns false once Stop or a newer job supersedes it;
    /// the job must then return without touching state.
    struct ExclusiveJob {
        let isCurrent: @MainActor () -> Bool
        let finish: @MainActor () -> Void
    }
    /// Runs `body` as the only active job. Finishing, cancellation and error reporting live here, so every job
    /// checks the same invariant: no state changes after the job is superseded.
    @discardableResult func runExclusive(_ context: String, progress: String? = nil, onFailure: (@MainActor () -> Void)? = nil,
                                         _ body: @escaping @MainActor (ExclusiveJob) async throws -> Void) -> UUID {
        let token = turn.begin(.generating); error = nil
        if let progress { helpProgress = progress }
        let job = ExclusiveJob(isCurrent: { [weak self] in !Task.isCancelled && self?.turn.epoch == token },
                               finish: { [weak self] in
                                   guard let self, self.turn.epoch == token else { return }
                                   if progress != nil { self.helpProgress = nil }
                                   _ = self.turn.finish(token)
                               })
        task = Task { [weak self] in
            do {
                try await body(job)
                if job.isCurrent() { job.finish() }
            } catch {
                guard let self, self.turn.epoch == token else { return }
                onFailure?(); self.fail(error,token:token,context:context)
            }
        }
        return token
    }
    func removeUnreferencedRecording(_ name: String?) {
        do { try libraryController.removeUnreferencedRecording(name,protected:messageDeletionUndo?.message.audio) }
        catch {
            MochiLog.failure(MochiLog.library,"Remove discarded recording",error,level:.info)
            self.error = "Could not remove the discarded recording. Reveal the data folder in Settings to review it."
        }
    }
    func fail(_ failure: Error, token: UUID, context: String = "Operation") {
        guard turn.epoch == token else { return }
        _ = turn.finish(token); greetingActive = false; speaking = false; recordingMeaning = false
        helpProgress = nil; recordingLevel = -80
        guard !(failure is CancellationError) else { return }
        MochiLog.failure(MochiLog.app,context,failure)
        error = AppFailure.message(for:failure,fallback:"This operation could not finish. Check the selected audio file or your connection, then retry.")
    }
    private func seedPreview() {
        var chat = Conversation(title:"A thought I've been putting off")
        chat.messages = [Message(role:"assistant",text:"What's been on your mind today?"),Message(role:"user",text:"I have an idea for a small project, but I haven't started yet."),Message(role:"assistant",text:"What's making it hard to get started?")]
        library.conversations = [chat,Conversation(title:"An idea over coffee"),Conversation(title:"The book I’m reading")]
        selectedID = chat.id; turn.pause(); helpStage = .practice; meaning = "I know what I mean. I just need the words."
        english = "I keep putting it off because I don't know where to start."
        var item = PracticeExpression(conversationID:chat.id,meaning:meaning,english:english)
        item.referenceKind = "Preview · illustrative contours"; expression = item
        referencePitch = (0..<180).map { i in
            let t = Double(i)
            let frequency: Double = 145 + 24 * sin(t * 0.07) + 7 * sin(t * 0.25)
            return PitchPoint(time:t * 0.025,hz:i % 37 < 4 ? nil : frequency)
        }
        attemptPitch = (0..<180).map { i in
            let t = Double(i)
            let frequency: Double = 151 + 16 * sin(t * 0.07 + 0.3)
            return PitchPoint(time:t * 0.027,hz:i % 39 < 5 ? nil : frequency)
        }
    }
}
