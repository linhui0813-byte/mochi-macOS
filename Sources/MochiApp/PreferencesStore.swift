import Foundation
import MochiCore
import MochiKernel

/// The app's stored settings. Stored values that no longer validate fall back to defaults, and the log names them.
@MainActor @Observable final class PreferencesStore {
    @ObservationIgnored let defaults: UserDefaults
    var modelName: String { didSet { defaults.set(modelName, forKey: "model") } }
    var conversationVoice: String { didSet { defaults.set(conversationVoice, forKey: "conversationVoice") } }
    var builtInPracticeVoice: String { didSet { defaults.set(builtInPracticeVoice, forKey: "builtInPracticeVoice") } }
    var conversationVoiceOptions: OpenAIVoiceOptions {
        didSet { store(conversationVoiceOptions, key: "conversationVoiceOptions") }
    }
    var practiceVoiceOptions: OpenAIVoiceOptions { didSet { store(practiceVoiceOptions, key: "practiceVoiceOptions") } }
    var externalControlEnabled: Bool {
        didSet { defaults.set(externalControlEnabled, forKey: "externalControlEnabled") }
    }
    var practiceVoiceLabel: String { "\(RealtimeVoice(rawValue:builtInPracticeVoice)?.name ?? "Marin") · Codex voice" }
    /// The last few greeting patterns, so a new conversation does not open with the same words.
    var recentGreetings: [String] {
        get { defaults.stringArray(forKey: "voiceGreetingHistory") ?? [] }
        set { defaults.set(Array(newValue.suffix(3)), forKey: "voiceGreetingHistory") }
    }

    /// - Parameters:
    ///   - importLegacy: copy settings that earlier app identities stored, without overwriting newer values.
    ///   - allowExternalControl: false for preview data, which must never be reachable from outside.
    init(_ defaults: UserDefaults, importLegacy: Bool, allowExternalControl: Bool) {
        self.defaults = defaults
        if importLegacy {
            for oldDomain in AppIdentity.legacyBundleIdentifiers {
                AppIdentity.migratePreferences(
                    into: defaults, legacy: defaults.persistentDomain(forName: oldDomain) ?? [:])
            }
        }
        func voice(_ key: String) -> String {
            guard let stored = defaults.string(forKey: key) else { return RealtimeService.defaultVoice }
            if let voice = RealtimeVoice(rawValue: stored) { return voice.rawValue }
            MochiLog.failure(
                MochiLog.app, "Stored preference \(key) names an unknown voice; using the default",
                AppFailure("Unknown voice."), level: .default)
            return RealtimeService.defaultVoice
        }
        func options(_ key: String) -> OpenAIVoiceOptions {
            guard let data = defaults.data(forKey: key) else { return OpenAIVoiceOptions() }
            do {
                let value = try JSONDecoder().decode(OpenAIVoiceOptions.self, from: data)
                try value.validate()
                return value
            } catch {
                MochiLog.failure(
                    MochiLog.app, "Stored preference \(key) was rejected; using the default", error, level: .default)
                return OpenAIVoiceOptions()
            }
        }
        modelName = defaults.string(forKey: "model") ?? RealtimeService.defaultModel
        conversationVoice = voice("conversationVoice")
        builtInPracticeVoice = voice("builtInPracticeVoice")
        conversationVoiceOptions = options("conversationVoiceOptions")
        practiceVoiceOptions = options("practiceVoiceOptions")
        externalControlEnabled = allowExternalControl && defaults.bool(forKey: "externalControlEnabled")
    }
    /// Mochi's conversation voice, optionally at one conversation's own speed.
    func conversationService(speed: Double? = nil) -> RealtimeService {
        var options = conversationVoiceOptions
        if let speed { options.speed = speed }
        return RealtimeService(model: modelName, voice: conversationVoice, options: options)
    }
    /// The voice for practice examples, or another voice being previewed.
    func practiceService(voice: String? = nil, options: OpenAIVoiceOptions? = nil) -> RealtimeService {
        RealtimeService(
            model: modelName, voice: voice ?? builtInPracticeVoice, options: options ?? practiceVoiceOptions)
    }
    private func store(_ value: OpenAIVoiceOptions, key: String) {
        do { defaults.set(try JSONEncoder().encode(value), forKey: key) } catch {
            MochiLog.failure(MochiLog.app, "Save preference \(key)", error)
        }
    }
}
