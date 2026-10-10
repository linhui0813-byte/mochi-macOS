import Foundation
import os

/// Unified-log channels. Read them with:
/// `log show --predicate 'subsystem == "com.lixiaolai.mochi-macos"' --info`
public enum MochiLog {
    public static let app = Logger(subsystem: AppIdentity.bundleIdentifier, category: "app")
    public static let library = Logger(subsystem: AppIdentity.bundleIdentifier, category: "library")
    public static let network = Logger(subsystem: AppIdentity.bundleIdentifier, category: "network")
    public static let audio = Logger(subsystem: AppIdentity.bundleIdentifier, category: "audio")
    public static let automation = Logger(subsystem: AppIdentity.bundleIdentifier, category: "automation")

    /// Records a failure with its cause chain. Domains, codes and Mochi's own messages are public;
    /// system descriptions are private because they can contain paths or user text.
    public static func failure(_ logger: Logger, _ context: String, _ error: Error, level: OSLogType = .error) {
        let summary = ErrorChain.causes(of: error).map { item in
            if let failure = item as? AppFailure { return "AppFailure: \(failure.message)" }
            let ns = item as NSError
            return "\(ns.domain) \(ns.code)"
        }.joined(separator: " <- ")
        let detail = String(describing: error)
        logger.log(
            level: level, "\(context, privacy: .public): \(summary, privacy: .public) | \(detail, privacy: .private)")
    }
}

/// Walks an error and its recorded causes.
public enum ErrorChain {
    public static func causes(of error: Error, limit: Int = 6) -> [Error] {
        var chain: [Error] = []
        var current: Error? = error
        while let item = current, chain.count < limit {
            chain.append(item)
            current = (item as? AppFailure)?.underlying ?? (item as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return chain
    }
    /// True when any cause is a full disk or an exhausted quota.
    public static func isOutOfSpace(_ error: Error) -> Bool {
        causes(of: error).contains { item in
            if item is AppFailure { return false }
            let ns = item as NSError
            return (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
                || (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT)))
        }
    }
}
