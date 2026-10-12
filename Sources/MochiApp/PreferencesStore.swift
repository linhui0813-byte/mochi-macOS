import Foundation
import MochiCore
import MochiKernel
import MochiProviders

/// The app's stored settings. Stored values that no longer validate fall back to defaults, and the log names them.
@MainActor @Observable final class PreferencesStore {
    @ObservationIgnored let defaults: UserDefaults
    /// The Model field as typed. A blank value is not stored, so the default returns after a restart.
    var modelName: String {
        didSet {
            if Self.trimmed(modelName) == nil {
                defaults.removeObject(forKey: "model")
            } else {
                defaults.set(modelName, forKey: "model")
            }
        }
    }
    /// The model services use: the typed name without surrounding spaces, or the default when it is blank.
    var effectiveModelName: String { Self.trimmed(modelName) ?? RealtimeService.defaultModel }
    /// What Mochi calls the user, as typed. Empty until the user gives a name, and a blank name is not stored.
    var userName: String {
        didSet {
            if Self.trimmed(userName) == nil {
                defaults.removeObject(forKey: "userName")
            } else {
                defaults.set(userName, forKey: "userName")
            }
        }
    }
    /// The name replies use: the typed name without surrounding spaces, or nil when it is blank or unusable.
    var effectiveUserName: String? { VoiceIdentity.usable(userName) }
    var conversationVoice: String { didSet { defaults.set(conversationVoice, forKey: "conversationVoice") } }
    var builtInPracticeVoice: String { didSet { defaults.set(builtInPracticeVoice, forKey: "builtInPracticeVoice") } }
    var conversationVoiceOptions: OpenAIVoiceOptions {
        didSet { store(conversationVoiceOptions, key: "conversationVoiceOptions") }
    }
    var practiceVoiceOptions: OpenAIVoiceOptions { didSet { store(practiceVoiceOptions, key: "practiceVoiceOptions") } }
    var externalControlEnabled: Bool {
        didSet { defaults.set(externalControlEnabled, forKey: "externalControlEnabled") }
    }
    /// The language new conversations start in.
    var defaultLanguage: ConversationLanguage {
        didSet { defaults.set(defaultLanguage.rawValue, forKey: "defaultLanguage") }
    }
    /// The order of the conversation list.
    var historySort: HistorySort { didSet { defaults.set(historySort.rawValue, forKey: "historySort") } }
    /// Whether Mochi sits on the desktop outside the workspace.
    var petVisible: Bool { didSet { defaults.set(petVisible, forKey: "desktopPetVisible") } }
    /// Whether the desktop Mochi's eyes follow the pointer while she is idle; off unless turned on.
    var petFollowsPointer: Bool { didSet { defaults.set(petFollowsPointer, forKey: "desktopPetFollowsPointer") } }
    /// Where the desktop Mochi was left, in screen coordinates; nil until she is first moved.
    var petOrigin: CGPoint? {
        didSet {
            if let petOrigin, petOrigin.x.isFinite, petOrigin.y.isFinite {
                defaults.set([Double(petOrigin.x), Double(petOrigin.y)], forKey: "desktopPetOrigin")
            } else {
                defaults.removeObject(forKey: "desktopPetOrigin")
            }
        }
    }
    /// Shortcuts that work in every app. An action without one is absent.
    /// Stored only when it differs from the default: a removed shortcut is stored as empty data, so it stays removed,
    /// and an action left at its default follows the default.
    var shortcuts: [ShortcutAction: Shortcut] {
        didSet {
            for action in ShortcutAction.allCases {
                switch shortcuts[action] {
                case action.defaultShortcut: defaults.removeObject(forKey: action.preferenceKey)
                case nil: defaults.set(Data(), forKey: action.preferenceKey)
                case let shortcut?:
                    do { defaults.set(try JSONEncoder().encode(shortcut), forKey: action.preferenceKey) } catch {
                        MochiLog.failure(MochiLog.app, "Save preference \(action.preferenceKey)", error)
                    }
                }
            }
        }
    }
    var practiceVoiceLabel: String {
        "\(RealtimeVoice(rawValue: builtInPracticeVoice)?.name ?? RealtimeService.defaultVoice.capitalized) · Codex voice"
    }
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
        modelName = defaults.string(forKey: "model").flatMap(Self.trimmed) ?? RealtimeService.defaultModel
        userName = defaults.string(forKey: "userName") ?? ""
        defaultLanguage =
            defaults.string(forKey: "defaultLanguage").flatMap(ConversationLanguage.init(rawValue:)) ?? .english
        historySort = defaults.string(forKey: "historySort").flatMap(HistorySort.init(rawValue:)) ?? .recent
        conversationVoice = voice("conversationVoice")
        builtInPracticeVoice = voice("builtInPracticeVoice")
        conversationVoiceOptions = options("conversationVoiceOptions")
        practiceVoiceOptions = options("practiceVoiceOptions")
        externalControlEnabled = allowExternalControl && defaults.bool(forKey: "externalControlEnabled")
        petVisible = defaults.bool(forKey: "desktopPetVisible")
        petFollowsPointer = defaults.bool(forKey: "desktopPetFollowsPointer")
        if let point = defaults.array(forKey: "desktopPetOrigin") as? [Double], point.count == 2,
            point.allSatisfy(\.isFinite)
        {
            petOrigin = CGPoint(x: point[0], y: point[1])
        } else {
            petOrigin = nil
        }
        var shortcuts = ShortcutAction.defaults
        for action in ShortcutAction.allCases {
            guard let data = defaults.data(forKey: action.preferenceKey) else { continue }
            if data.isEmpty {
                shortcuts[action] = nil
                continue
            }
            do {
                let shortcut = try JSONDecoder().decode(Shortcut.self, from: data)
                if let problem = shortcut.problem { throw AppFailure(verbatim: problem) }
                shortcuts[action] = shortcut
            } catch {
                MochiLog.failure(
                    MochiLog.app, "Stored preference \(action.preferenceKey) was rejected; using the default", error,
                    level: .default)
            }
        }
        self.shortcuts = shortcuts
    }
    /// Mochi's conversation voice, optionally at one conversation's own speed.
    func conversationService(speed: Double? = nil) -> RealtimeService {
        var options = conversationVoiceOptions
        if let speed { options.speed = speed }
        return RealtimeService(model: effectiveModelName, voice: conversationVoice, options: options)
    }
    /// The voice for practice examples, or another voice being previewed.
    func practiceService(voice: String? = nil, options: OpenAIVoiceOptions? = nil) -> RealtimeService {
        RealtimeService(
            model: effectiveModelName, voice: voice ?? builtInPracticeVoice, options: options ?? practiceVoiceOptions)
    }
    private static func trimmed(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    private func store(_ value: OpenAIVoiceOptions, key: String) {
        do { defaults.set(try JSONEncoder().encode(value), forKey: key) } catch {
            MochiLog.failure(MochiLog.app, "Save preference \(key)", error)
        }
    }
}
