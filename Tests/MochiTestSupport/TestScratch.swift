import Foundation

/// Every folder and preferences suite a test process creates lives under one scratch folder,
/// which is removed when the process exits.
///
/// Preferences suites are named by absolute path, so their files are written inside that folder
/// rather than ~/Library/Preferences. Removing a named domain there leaves its file behind, and the
/// preferences daemon can write it again after the test has deleted it.
public enum TestScratch {
    /// Short on purpose: socket tests place Unix socket paths here, which are limited to 104 bytes.
    private static let root: URL = {
        let root = URL(fileURLWithPath: "/tmp/mochi-tests-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("preferences"), withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/tmp/mochi-tests-\(getpid())")) }
        return root
    }()

    /// A fresh path inside this process's scratch folder. The folder itself is not created.
    public static func folder(_ prefix: String = "mochi") -> URL {
        root.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    /// A fresh preferences suite stored inside the scratch folder.
    public static func preferences(_ prefix: String = "mochi-test") -> (defaults: UserDefaults, name: String) {
        let name = "\(prefix)-\(UUID().uuidString)"
        return (preferences(named: name), name)
    }

    /// The suite with exactly this name, for tests that reopen the same preferences.
    public static func preferences(named name: String) -> UserDefaults {
        UserDefaults(suiteName: root.appendingPathComponent("preferences").appendingPathComponent(name).path)!
    }
}
