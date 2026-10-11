import Foundation

/// Identity shared by the app, its data folder and the MCP helper.
public enum AppIdentity {
    public static let name = "Mochi"
    public static let bundleIdentifier = "com.lixiaolai.mochi-macos"
    public static let previousBundleIdentifier = "com.xiaolai.mochi-macos"
    public static let legacyBundleIdentifiers = [previousBundleIdentifier, legacyBundleIdentifier]
    public static let legacyBundleIdentifier = "com.xiaolai.enjoy-myself"
    public static let legacyDataDirectory = "Enjoy Myself"
    public static let backupType = "com.lixiaolai.mochi-macos.library"
    public static let repositoryURL = URL(string: "https://github.com/xiaolai/mochi-macOS")!
    public static let authorURL = URL(string: "https://lixiaolai.com")!
}
