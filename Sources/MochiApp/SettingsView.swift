import SwiftUI

struct SettingsView: View {
    @Bindable var app: AppModel

    var body: some View {
        TabView(selection: $app.settingsTab) {
            Form {
                Section("Connection") {
                    LabeledContent("Sign-in", value: "Codex")
                    Text("Sign in through Codex on this Mac, then check the connection here.").font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Model", text: Bindable(app.settings).modelName).textFieldStyle(.roundedBorder).disabled(
                        app.busy
                    )
                    .onChange(of: app.settings.modelName) { app.serviceStatus = String(localized: "Not checked") }
                    LabeledContent("Status") { Text(app.serviceStatus).foregroundStyle(.secondary) }
                    Button("Check Connection", action: app.checkConnection).disabled(app.busy)
                }
                Section {
                    Text(
                        "Checking the connection sends a short text request. Recordings are sent only when you finish a voice message or choose to translate a recorded thought."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                feedback
            }.formStyle(.grouped)
                .tabItem { Label("Conversation", systemImage: "bubble.left.and.bubble.right") }.tag("conversation")

            VoiceSettingsView(app: app)
                .tabItem { Label("Voices", systemImage: "waveform") }.tag("voices")

            DesktopPetSettingsView(app: app)
                .tabItem { Label("Desktop", systemImage: "macwindow.on.rectangle") }.tag("desktop")

            AutomationSettingsView(app: app)
                .tabItem { Label("Automation", systemImage: "switch.2") }.tag("automation")

            Form {
                Section("Storage") {
                    LabeledContent("Conversations and recordings", value: "On this Mac")
                    LabeledContent("Sign-in", value: "Your local Codex session")
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
                        "Library backups include conversations and practice audio, not sign-in credentials. Provider processing and retention follow your account settings."
                    ).foregroundStyle(.secondary)
                }
                feedback
                if let feedback = app.history.feedback { Text(feedback).font(.callout).foregroundStyle(.secondary) }
            }.formStyle(.grouped)
                .tabItem { Label("Data & Privacy", systemImage: "hand.raised") }.tag("privacy")

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .padding(12)
        .frame(width: 620, height: 560)
    }

    private var canTransferLibrary: Bool { app.libraryReadable && app.libraryTransfer == nil }

    @ViewBuilder private var feedback: some View {
        if let error = app.error { Text(error).font(.callout).foregroundStyle(.red) }
    }

}
