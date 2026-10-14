import MochiCore
import SwiftUI

/// The Settings window's tabs, in the order they appear.
enum SettingsTab: Hashable { case general, voices, desktopMochi, automation, privacy, about }

struct SettingsView: View {
    @Bindable var app: AppModel

    var body: some View {
        TabView(selection: $app.settingsTab) {
            Form {
                Section("You") {
                    TextField("Your name", text: Bindable(app.settings).userName).textFieldStyle(.roundedBorder)
                    if app.settings.effectiveUserName == nil
                        && !app.settings.userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        Text(
                            "Mochi can’t use this name. Use up to \(ConversationTemplate.nameLimit.characters) characters on one line."
                        ).font(.caption).foregroundStyle(.red)
                    }
                    Text("Mochi calls you by this name. Leave it empty and she won’t use one.").font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("New Conversations") {
                    LanguagePicker(selection: Bindable(app.settings).defaultLanguage)
                    Text("Existing conversations and templates keep their own language.").font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Connection") {
                    LabeledContent("Sign-in", value: "Codex")
                    Text("Sign in through Codex on this Mac, then check the connection here.").font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Model", text: Bindable(app.settings).modelName).textFieldStyle(.roundedBorder).disabled(
                        app.busy
                    )
                    .onChange(of: app.settings.modelName) {
                        app.serviceStatus = String(localized: "Not checked")
                        app.speech.resetConversation()
                    }
                    LabeledContent("Status") { Text(app.serviceStatus).foregroundStyle(.secondary) }
                    Button("Check Connection", action: app.checkConnection).disabled(app.busy)
                }
                Section("Continuous conversation") {
                    Toggle("Continuous conversation", isOn: Bindable(app).continuousConversation)
                        .toggleStyle(.switch).disabled(app.busy && !app.handsFreeActive && !app.handsFreeStarting)
                        .accessibilityIdentifier("continuous-conversation")
                    Text(
                        "On: start once, speak hands-free, and interrupt Mochi by speaking. Off: record each message manually."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    Text(
                        "Press the microphone button or shortcut to start. Press it again, or Stop, to end the conversation."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    TextField("Spoken ending phrase", text: Bindable(app.settings).endingPhrase)
                        .textFieldStyle(.roundedBorder).disabled(app.busy || app.endingPhrasePreparing)
                        .accessibilityIdentifier("spoken-ending-phrase")
                        .onChange(of: app.settings.endingPhrase) { app.cancelEndingPhrasePreparation() }
                    Text(
                        "Say this phrase to send your turn even when background noise continues. Pause detection still works."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    Text(
                        "Use a distinctive English phrase of up to eight words, such as “over over”. Leave blank to disable."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if !app.settings.endingPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        app.settings.effectiveEndingPhrase == nil
                    {
                        Text("Use 1–8 English words, up to 64 characters, on one line.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    LabeledContent("Ending phrase status") { Text(app.endingPhraseStatus).foregroundStyle(.secondary) }
                    Button("Prepare phrase recognition", action: app.checkEndingPhrase)
                        .disabled(app.busy || app.endingPhrasePreparing || app.settings.effectiveEndingPhrase == nil)
                    Text(
                        "Recognition stays on this Mac. Preparing it may download Apple's speech model; it does not turn on the microphone."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                KeyboardShortcutsSection(app: app)
                feedback(.general)
            }.formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)

            VoiceSettingsView(app: app)
                .tabItem { Label("Voices", systemImage: "waveform") }.tag(SettingsTab.voices)

            DesktopPetSettingsView(app: app)
                .tabItem { Label("Desktop Mochi", systemImage: "macwindow.on.rectangle") }.tag(SettingsTab.desktopMochi)

            AutomationSettingsView(app: app)
                .tabItem { Label("Automation", systemImage: "switch.2") }.tag(SettingsTab.automation)

            Form {
                Section("Storage") {
                    LabeledContent("Conversations and recordings", value: "On this Mac")
                    Button("Export Library Backup…", action: app.exportLibraryBackup).disabled(!canTransferLibrary)
                    Button("Import Library Backup…", action: app.importLibraryBackup).disabled(!canTransferLibrary)
                    Button("Show Data Folder…", action: app.revealDataFolder)
                    if app.canRestorePreviousLibrary {
                        Button("Restore Earlier Copy…", action: app.restorePreviousLibrary)
                        Text(
                            "Reinstates the library saved just before the unreadable one. The unreadable file is kept in the data folder."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Privacy") {
                    Text(
                        "Conversation text, context, and voice messages go to OpenAI through your Codex sign-in. Example text is voiced by OpenAI through the same sign-in. Practice attempts and pitch analysis stay on your Mac."
                    )
                    Text(
                        "Checking the connection sends a short text request. In continuous conversation, the microphone stays on until you stop; detected speech is sent automatically. In manual mode, recordings are sent when you finish a voice message or translate a recorded thought."
                    )
                    Text(
                        "Library backups include conversations and practice audio, not sign-in credentials. Provider processing and retention follow your account settings."
                    ).foregroundStyle(.secondary)
                    Text(
                        "Spoken ending phrases are detected on this Mac using Apple's local English speech model. Recognition runs only while you have started continuous conversation."
                    )
                }
                feedback(.privacy)
                if let feedback = app.history.feedback { Text(feedback).font(.callout).foregroundStyle(.secondary) }
            }.formStyle(.grouped)
                .tabItem { Label("Data & Privacy", systemImage: "hand.raised") }.tag(SettingsTab.privacy)

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .padding(12)
        .frame(width: 620, height: 560)
    }

    private var canTransferLibrary: Bool { app.libraryReadable && app.libraryTransfer == nil }

    /// The error of an action started from this tab; errors from elsewhere belong to the window that caused them.
    @ViewBuilder private func feedback(_ tab: SettingsTab) -> some View {
        if let error = app.error, app.errorTab == tab { Text(error).font(.callout).foregroundStyle(.red) }
    }

}
