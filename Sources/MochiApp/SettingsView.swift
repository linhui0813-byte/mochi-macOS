import MochiCore
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
                    TextField("Model", text: Bindable(app.settings).modelName).disabled(app.busy)
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

            AutomationSettingsView(app: app)
                .tabItem { Label("Automation", systemImage: "switch.2") }.tag("automation")

            Form {
                Section("Storage") {
                    LabeledContent("Conversations and recordings", value: "On this Mac")
                    LabeledContent("Sign-in", value: "Your local Codex session")
                    Button("Export Library Backup…", action: app.exportLibraryBackup).disabled(
                        app.libraryTransfer != nil)
                    Button("Import Library Backup…", action: app.importLibraryBackup).disabled(
                        app.libraryTransfer != nil)
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
                Section("Mochi") {
                    Text("Original character and artwork © Xiaolai. Used with permission.").foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
                .tabItem { Label("Data & Privacy", systemImage: "hand.raised") }.tag("privacy")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text(
                "Mochi \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "Development") (build \(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "Development"))"
            )
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled).padding(.top, 8)
        }
        .padding(12)
        .frame(width: 620, height: 560)
    }

    @ViewBuilder private var feedback: some View {
        if let error = app.error { Text(error).font(.callout).foregroundStyle(.red) }
    }

}
