import MochiCore
import SwiftUI

struct BuiltInVoicePicker: View {
    let title: String
    @Binding var selection: String
    @Bindable var app: AppModel
    var options: OpenAIVoiceOptions? = nil
    var body: some View {
        HStack {
            Picker(title, selection: $selection) {
                ForEach(RealtimeVoice.allCases) { voice in Text(voice.name).tag(voice.rawValue) }
            }
            Button {
                app.previewBuiltIn(selection, options: options)
            } label: {
                Label("Preview", systemImage: "play.fill")
            }
        }.disabled(app.busy)
    }
}
struct PracticeVoiceControls: View {
    @Bindable var app: AppModel
    var body: some View {
        BuiltInVoicePicker(
            title: "Example voice", selection: Bindable(app.settings).builtInPracticeVoice, app: app,
            options: app.settings.practiceVoiceOptions)
        OpenAIVoiceOptionsView(options: Bindable(app.settings).practiceVoiceOptions)
    }
}
struct VoiceSettingsView: View {
    @Bindable var app: AppModel
    var body: some View {
        Form {
            Section("Mochi’s Conversation Voice") {
                BuiltInVoicePicker(
                    title: "Voice", selection: Bindable(app.settings).conversationVoice, app: app,
                    options: app.settings.conversationVoiceOptions)
                OpenAIVoiceOptionsView(options: Bindable(app.settings).conversationVoiceOptions, expanded: app.demo)
                    .disabled(app.busy)
                Text("Voice changes apply to new replies.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Practice Examples") {
                PracticeVoiceControls(app: app).disabled(app.busy)
                Text("Saved recordings keep their original voice.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = app.error { Text(error).font(.callout).foregroundStyle(.red) }
            // Stop Preview ends only the preview's own turn; other activity keeps the main Stop.
            if app.previewActive { Button("Stop Preview") { app.stopPreview() } }
        }.formStyle(.grouped)
    }
}
