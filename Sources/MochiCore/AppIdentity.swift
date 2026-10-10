import Darwin
import Foundation
import MochiKernel

extension AppIdentity {
    /// Copy first, then atomically install the directory; leave original data intact.
    public static func prepareDataDirectory(in support: URL) throws -> URL {
        let destination = support.appendingPathComponent(name)
        let legacy = support.appendingPathComponent(legacyDataDirectory)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try validateDirectory(destination)
            if fm.fileExists(atPath: destination.appendingPathComponent("library.json").path) { return destination }
        }
        // Without an older library there is nothing to migrate: caches or Finder files in the folder are harmless.
        guard fm.fileExists(atPath: legacy.path) else { return destination }
        if fm.fileExists(atPath: destination.path) {
            guard try fm.contentsOfDirectory(atPath: destination.path).isEmpty else {
                throw AppFailure(
                    "the Mochi folder already contains other files, so your library in the “\(legacyDataDirectory)” folder was not moved. Move those files out of the Mochi folder and reopen Mochi."
                )
            }
        }
        try validateDirectory(legacy)
        _ = try LibraryStore(root: legacy).load()  // Corrupt/future data stays untouched.
        let staging = support.appendingPathComponent(".mochi-migration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: legacy, to: staging)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        if fm.fileExists(atPath: destination.path) {
            // rmdir only succeeds for an empty directory; never recursively erase a destination.
            guard Darwin.rmdir(destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        try fm.moveItem(at: staging, to: destination)
        return destination
    }
    /// True when an older library must be copied into the Mochi folder before it can open.
    public static func needsMigration(in support: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: support.appendingPathComponent(legacyDataDirectory).path)
            && !fm.fileExists(atPath: support.appendingPathComponent(name).appendingPathComponent("library.json").path)
    }
    /// Removes copies left by a migration that was interrupted, for example by a force quit. The original stays untouched.
    public static func sweepStaleMigrations(in support: URL, olderThan age: TimeInterval = 3600, now: Date = Date()) {
        let fm = FileManager.default
        guard
            let items = try? fm.contentsOfDirectory(
                at: support,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
        else { return }
        for url in items where url.lastPathComponent.hasPrefix(".mochi-migration-") {
            guard
                let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
                ]),
                values.isDirectory == true, values.isSymbolicLink != true,
                let modified = values.contentModificationDate, now.timeIntervalSince(modified) > age
            else { continue }
            do { try fm.removeItem(at: url) } catch {
                MochiLog.failure(MochiLog.library, "Remove interrupted migration copy", error, level: .info)
            }
        }
    }
    /// The folder to reveal when preparation fails: the conflicting Mochi folder, else the older library.
    public static func recoveryFolder(in support: URL) -> URL {
        let fm = FileManager.default
        let destination = support.appendingPathComponent(name)
        let legacy = support.appendingPathComponent(legacyDataDirectory)
        if let items = try? fm.contentsOfDirectory(atPath: destination.path), !items.isEmpty { return destination }
        return fm.fileExists(atPath: legacy.path) ? legacy : support
    }
    public static func migratePreferences(into defaults: UserDefaults, legacy: [String: Any]) {
        for key in [
            "auth", "model", "clone", "performer", "conversationVoice", "builtInPracticeVoice", "practiceVoiceMode",
        ] where defaults.object(forKey: key) == nil {
            if let value = legacy[key] as? String { defaults.set(value, forKey: key) }
        }
        for key in ["voiceProfiles", "conversationVoiceOptions", "practiceVoiceOptions", "personalVoiceOptions"]
        where defaults.object(forKey: key) == nil {
            if let value = legacy[key] as? Data { defaults.set(value, forKey: key) }
        }
        if defaults.object(forKey: "voiceGreetingHistory") == nil,
            let history = legacy["voiceGreetingHistory"] as? [String]
        {
            defaults.set(history, forKey: "voiceGreetingHistory")
        }
    }
    private static func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw AppFailure("The saved library folder is not a regular directory.")
        }
    }
}
