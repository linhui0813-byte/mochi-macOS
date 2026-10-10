import AppKit
import MochiKernel
import MochiCore

/// Owns the library and how it reaches disk: opening and migrating it at launch, immediate and debounced saves,
/// earlier-copy recovery, backup transfers and audio cleanup. It knows nothing about selection, playback or views.
@MainActor @Observable final class LibraryController {
    var library = Library() { didSet { if !quiet { revision = UUID(); onChange() } } }
    /// Changes whenever automation clients would see a different library. Typing and selection bookkeeping do not count.
    @ObservationIgnored private(set) var revision = UUID()
    /// False when the library could not be opened; every write is then refused so nothing on disk is replaced.
    private(set) var readable = true
    /// True when the library failed to load and the copy kept before the last save can be reinstated.
    private(set) var canRestorePrevious = false
    /// Shown while an older library is copied into Mochi's folder at launch.
    private(set) var startupProgress: String?
    /// Shown while a backup is exported or imported; one transfer runs at a time.
    private(set) var transfer: String?
    /// The folder "Show Data Folder" opens: the library, or the folder that needs attention after a failed migration.
    private(set) var dataFolder: URL
    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let demo: Bool
    @ObservationIgnored var saveDelay: UInt64 = 500_000_000
    /// The conversation to record as selected when saving.
    @ObservationIgnored var selection: @MainActor () -> UUID? = { nil }
    /// Receives user-facing failure messages.
    @ObservationIgnored var report: @MainActor (String) -> Void = { _ in }
    /// Called after every change that `revision` counts.
    @ObservationIgnored var onChange: @MainActor () -> Void = {}
    @ObservationIgnored private var pendingSave: Task<Void,Never>?
    @ObservationIgnored private var quiet = false

    init(root: URL, demo: Bool) { store = LibraryStore(root:root); dataFolder = root; self.demo = demo }

    var hasPendingSave: Bool { pendingSave != nil }
    /// Records typing or bookkeeping without changing `revision`.
    func updateQuietly(_ change: (inout Library) -> Void) {
        quiet = true; defer { quiet = false }
        change(&library)
    }

    // MARK: Opening

    /// Opens the library. A managed folder may first need an older library copied in; that copy runs in the
    /// background while `startupProgress` is shown, and `completion` runs once the library is open or has failed.
    func open(managedIn support: URL?, isolated: Bool, completion: @escaping @MainActor () -> Void) {
        guard let support else { load(isolated:isolated); completion(); return }
        AppIdentity.sweepStaleMigrations(in:support)
        if AppIdentity.needsMigration(in:support) {
            readable = false; startupProgress = "Moving your library into Mochi’s folder…"
            Task { [weak self] in
                let outcome = await Task.detached { Result { try AppIdentity.prepareDataDirectory(in:support) } }.value
                guard let self else { return }
                startupProgress = nil
                switch outcome {
                case .success: readable = true; load(isolated:false)
                case .failure(let error): preparationFailed(error,support:support)
                }
                completion()
            }
            return
        }
        do { _ = try AppIdentity.prepareDataDirectory(in:support); load(isolated:false) }
        catch { preparationFailed(error,support:support) }
        completion()
    }
    private func preparationFailed(_ error: Error, support: URL) {
        MochiLog.failure(MochiLog.library,"Prepare data folder",error)
        readable = false; dataFolder = AppIdentity.recoveryFolder(in:support)
        report("Mochi could not move your library into its folder: \(AppFailure.message(for:error,fallback:"the folder could not be prepared.")) Your data has not been changed. Reveal the data folder from Settings to review it.")
    }
    /// Loads the library, or explains why it cannot be opened and offers the earlier copy when one exists.
    private func load(isolated: Bool) {
        do {
            try store.prepare(); library = try store.load()
            // Older builds predate the instance lock, so the sweep also requires that none of them is running.
            if isolated || SingleInstanceController.shared.ownsLibrary {
                do { try store.cleanupOrphanedAudio(library) } catch { MochiLog.failure(MochiLog.library,"Remove orphaned recordings",error,level:.info) }
            }
        } catch {
            MochiLog.failure(MochiLog.library,"Load library",error)
            readable = false
            canRestorePrevious = (try? store.loadPrevious()) != nil
            let cause = AppFailure.message(for:error,fallback:"The library file is damaged or incomplete.")
            report("Your saved library could not be opened. \(cause) It has not been overwritten. " + (canRestorePrevious ? "Choose Restore Earlier Copy in Settings → Storage to reinstate the version saved just before it." : "Reveal the data folder from Settings to recover it."))
        }
    }
    /// Reinstates the copy kept before the last save, setting the unreadable file aside.
    func restorePrevious() throws {
        guard !readable, canRestorePrevious else { return }
        library = try store.restorePrevious()
        readable = true; canRestorePrevious = false
    }
    func revealDataFolder() -> Bool {
        FileManager.default.fileExists(atPath:dataFolder.path) && NSWorkspace.shared.open(dataFolder)
    }

    // MARK: Saving

    @discardableResult func save() -> Bool {
        pendingSave?.cancel(); pendingSave = nil
        guard readable else { return false }; if demo { return true }
        let selected = selection()
        if library.selectedConversationID != selected { updateQuietly { $0.selectedConversationID = selected } }
        do { try store.save(library); return true }
        catch {
            report(Self.persistenceMessage(error,action:"Save library",
                                           fallback:"Could not save your conversation. Keep this window open and try again.",
                                           diskFull:"Could not save your conversation because the disk is full. Free some space; keep this window open."))
            return false
        }
    }
    /// Coalesces typing into one write after a pause. Any immediate save also writes it.
    func scheduleSave() {
        guard readable, !demo else { return }
        pendingSave?.cancel()
        let delay = saveDelay
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            save()
        }
    }
    /// Writes a complete replacement library, then publishes it. Nothing changes if the write fails.
    func commit(_ candidate: Library) throws {
        guard readable else { throw AppFailure("Your library is unavailable. No changes were saved.") }
        var normalized = candidate; normalized.version = 3
        if !demo { try store.save(normalized); pendingSave?.cancel(); pendingSave = nil }
        library = normalized
    }
    /// The text for a failed write. Disk space is blamed only when it is the cause.
    static func persistenceMessage(_ error: Error, action: String, fallback: String, diskFull: String) -> String {
        let invariant = (error as? AppFailure)?.underlying is LibraryInvariantViolation
        MochiLog.failure(MochiLog.library,action,error,level:invariant ? .fault : .error)
        assert(!invariant, "\(action): the in-memory library violated an invariant")
        if ErrorChain.isOutOfSpace(error) { return diskFull }
        return AppFailure.message(for:error,fallback:fallback)
    }

    // MARK: Files

    /// Removes a recording nothing references any more. `protected` names a file an undo may still restore.
    func removeUnreferencedRecording(_ name: String?, protected: String? = nil) throws {
        guard let name, !name.isEmpty, URL(fileURLWithPath:name).lastPathComponent == name,
              !library.referencedAudio.contains(name), protected != name else { return }
        let url = store.root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath:url.path) else { return }
        try FileManager.default.removeItem(at:url)
    }
    /// Copies a snapshot of the library and its recordings off the main thread. The transfer is claimed at once,
    /// so a second request cannot start alongside it; nil means another transfer is running or the library is closed.
    func exportBackup(to url: URL) -> Task<Void,Error>? {
        guard readable, transfer == nil else { return nil }
        transfer = "Exporting your library backup…"
        let snapshot = library, root = store.root
        return Task { [weak self] in
            defer { self?.transfer = nil }
            try await Task.detached { try LibraryBackup.write(snapshot,from:root,to:url) }.value
        }
    }
    /// Reads a backup and copies its recordings off the main thread, then merges into the library as it is by then,
    /// so edits made meanwhile are kept. The task returns the import summary.
    func importBackup(from url: URL) -> Task<String,Error>? {
        guard readable, transfer == nil else { return nil }
        transfer = "Importing your library backup…"
        let snapshot = library, root = store.root
        return Task { [weak self] in
            defer { self?.transfer = nil }
            let (imported, prepared) = try await Task.detached { () throws -> (Library,LibraryBackup.PreparedImport) in
                let imported = try LibraryBackup.read(url)
                return (imported,try LibraryBackup.prepareMerge(imported,from:url,into:snapshot,root:root))
            }.value
            guard let self else { LibraryBackup.discard(prepared,keeping:Library()); throw CancellationError() }
            let templateIDsBeforeImport = Set(library.conversationTemplates.map(\.id))
            var candidate = library
            do {
                let count = try LibraryBackup.apply(prepared,to:&candidate)
                try commit(candidate)
                return ConversationTemplate.importSummary(conversations:count,imported:imported.conversationTemplates,merged:candidate.conversationTemplates,localIDs:templateIDsBeforeImport)
            } catch { LibraryBackup.discard(prepared,keeping:library); throw error }
        }
    }
}
