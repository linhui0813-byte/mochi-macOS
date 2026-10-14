import Foundation
import MochiKernel

/// Monotonic timing for one submitted voice turn. Logs fixed stage names and numbers only.
/// No audio, transcript, conversation identifier, credential or request content enters the log.
public final class VoiceReplyTiming: @unchecked Sendable {
    public enum Stage: String, Sendable {
        case submitted, connectionNew, connectionReused, pingReady, credentialReady, socketReady
        case contextCleared, sessionReady, audioSent, responseRequested, firstAudio, playbackQueued
        case responseFinished, transcriptionFinished
    }
    private let lock = NSLock()
    private let origin = ProcessInfo.processInfo.systemUptime
    private let id = String(UUID().uuidString.prefix(8))
    private var stages: [Stage: Int] = [:]
    public init() {}
    public func record(_ stage: Stage) {
        lock.lock()
        defer { lock.unlock() }
        guard stages[stage] == nil else { return }
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - origin) * 1000)
        stages[stage] = elapsed
        MochiLog.network.notice(
            "Voice timing id=\(self.id, privacy: .public) stage=\(stage.rawValue, privacy: .public) elapsed_ms=\(elapsed, privacy: .public)"
        )
    }
    public func elapsedMilliseconds(at stage: Stage) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return stages[stage]
    }
}
