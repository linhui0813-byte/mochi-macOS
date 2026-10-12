import MochiCore
import MochiKernel
import MochiProviders
import SwiftUI

/// The language a conversation is held in: one to speak and practise, or Match Me last, apart from the others.
struct LanguagePicker: View {
    @Binding var selection: ConversationLanguage
    var body: some View {
        Picker("Language", selection: $selection) {
            ForEach(ConversationLanguage.allCases.filter(\.isPractised), id: \.self) {
                Text(verbatim: $0.displayName).tag($0)
            }
            Divider()
            Text(verbatim: ConversationLanguage.match.displayName).tag(ConversationLanguage.match)
        }
    }
}

/// The voice of one setup: the Settings voice, one of Mochi's voices, or a stored voice this version does not
/// have, which is kept and listed until the user picks another.
struct CompanionVoicePicker: View {
    @Bindable var app: AppModel
    @Binding var voice: String?
    /// The setup's own speed, so the preview sounds as replies will.
    var speed: Double?
    private var unknown: String? { voice.flatMap { RealtimeVoice(rawValue: $0) == nil ? $0 : nil } }
    var body: some View {
        HStack {
            Picker("Voice", selection: $voice) {
                Text("Settings Voice (\(app.settings.conversationVoiceName))").tag(String?.none)
                Divider()
                ForEach(RealtimeVoice.allCases) { Text(verbatim: $0.name).tag(String?.some($0.rawValue)) }
                if let unknown {
                    Divider()
                    Text("\(unknown) (not available)").tag(String?.some(unknown))
                }
            }
            Button {
                var options = app.settings.conversationVoiceOptions
                if let speed { options.speed = speed }
                app.previewBuiltIn(
                    voice.flatMap(RealtimeVoice.init(rawValue:))?.rawValue ?? app.settings.conversationVoice,
                    options: options, settingsTab: nil)
            } label: {
                Label("Preview", systemImage: "play.fill")
            }.disabled(app.busy)
        }
        if unknown != nil {
            Text("This voice is not available in this version of Mochi, so the Settings voice speaks instead.")
                .font(.caption).foregroundStyle(.orange)
        }
        if app.voicePreviewFailed, let error = app.error {
            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The phrases of one setup: lines the user can send with one click.
struct PhraseListEditor: View {
    @Binding var phrases: [String]
    var body: some View {
        Text("Phrases").font(.subheadline).fontWeight(.medium)
        ForEach(phrases.indices, id: \.self) { index in
            HStack {
                TextField(
                    "Phrase \(index + 1)",
                    text: Binding(
                        get: { phrases.indices.contains(index) ? phrases[index] : "" },
                        set: { if phrases.indices.contains(index) { phrases[index] = $0 } })
                ).textFieldStyle(.roundedBorder)
                Button {
                    if phrases.indices.contains(index) { phrases.remove(at: index) }
                } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.borderless).help("Remove Phrase").accessibilityLabel("Remove Phrase \(index + 1)")
            }
        }
        Button("Add Phrase") { phrases.append("") }.disabled(phrases.count >= ConversationPhrases.maxCount)
        Text("Up to six lines you can send with one click, exactly as written. You can also type or say them.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Every setting of a conversation or template, in three groups: who the companion is, what you do together, and
/// the language. Used by Conversation Instructions, the template preview and the template editor.
struct ConversationSettingsFields<Settings: ConversationSettingsHolder>: View {
    @Bindable var app: AppModel
    @Binding var settings: Settings
    /// Given where the companion can be saved as a character and the editor can return to these settings.
    var saveAsCharacter: (() -> Void)?
    @FocusState private var focused: Field?
    private enum Field { case personality, instructions }
    var body: some View {
        companion
        Divider().padding(.vertical, 4)
        activity
        Divider().padding(.vertical, 4)
        language
    }

    @ViewBuilder private var companion: some View {
        HStack {
            Text("Character").font(.headline)
            Spacer()
            Menu("Choose Character") {
                let pickable = app.pickableCharacters
                ForEach(CharacterSection.allCases, id: \.self) { section in
                    let members = pickable.filter { ($0.isBuiltin ? CharacterSection.builtIn : .mine) == section }
                    if !members.isEmpty {
                        Section(section.title) {
                            ForEach(members) { character in
                                Toggle(
                                    isOn: Binding(
                                        get: { settings.hasCharacter(character) },
                                        set: { _ in settings.adoptCharacter(character) })
                                ) { Text(verbatim: character.name) }
                            }
                        }
                    }
                }
            }.fixedSize().accessibilityIdentifier("choose-character")
            if let saveAsCharacter { Button("Save as Character…", action: saveAsCharacter) }
        }
        Text("Choosing a character copies its name, personality and voice into these settings.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle(
            "Use a custom character name",
            isOn: Binding(
                get: { settings.characterName != nil }, set: { settings.characterName = $0 ? "Mochi" : nil }))
        if settings.characterName != nil {
            TextField(
                "Character name",
                text: Binding(get: { settings.characterName ?? "" }, set: { settings.characterName = $0 })
            )
            .textFieldStyle(.roundedBorder).accessibilityIdentifier("character-name")
        }
        Text(
            settings.characterName == nil
                ? "Default identity: Mochi. Instructions can override its conversational name."
                : "This name takes precedence over naming in instructions. Saved messages keep their original speaker name."
        )
        .font(.caption).foregroundStyle(.secondary)
        Text("Personality").font(.subheadline).fontWeight(.medium)
        TextEditor(text: $settings.personality).font(.body).padding(6).frame(height: 70)
            .focused($focused, equals: .personality)
            .fieldFrame(cornerRadius: 8, focused: focused == .personality)
            .accessibilityLabel("Personality")
        Text("How the companion comes across. The instructions decide what you do together.")
            .font(.caption).foregroundStyle(.secondary)
        CompanionVoicePicker(app: app, voice: $settings.preferences.voice, speed: settings.preferences.speed)
    }

    @ViewBuilder private var activity: some View {
        Text("Instructions").font(.headline)
        TextEditor(text: $settings.instructions).font(.body).padding(6).frame(height: 150)
            .focused($focused, equals: .instructions)
            .fieldFrame(cornerRadius: 8, focused: focused == .instructions)
            .accessibilityLabel("Conversation instructions")
        Text(
            "\(settings.instructions.count)/\(ConversationInstructions.maxCharacters.formatted()) characters · \(settings.instructions.utf8.count)/\(ConversationInstructions.maxBytes.formatted()) bytes"
        )
        .font(.caption).foregroundStyle(.secondary)
        if settings.instructions.count > ConversationInstructions.maxCharacters
            || settings.instructions.utf8.count > ConversationInstructions.maxBytes
        {
            Text(
                "The full original text is preserved. Future replies use a bounded preview. Shorten it to \(ConversationInstructions.maxCharacters.formatted()) characters and \(ConversationInstructions.maxBytes / 1024) KB to save edited text or a new template. Unchanged conversation text can be preserved when changing other settings."
            )
            .font(.caption).foregroundStyle(.red)
        }
        Text("Greeting").font(.subheadline).fontWeight(.medium)
        TextField("Greeting", text: $settings.greeting).textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("greeting")
        Text(
            "Spoken exactly as written when you first start talking. Leave it empty for a standard greeting in the conversation’s language."
        )
        .font(.caption).foregroundStyle(.secondary)
        PhraseListEditor(phrases: $settings.phrases)
    }

    @ViewBuilder private var language: some View {
        LanguagePicker(selection: $settings.preferences.language)
        Picker("Coaching", selection: $settings.preferences.coaching) {
            Text("Natural conversation").tag(CoachingStyle.natural)
            Text("Occasional gentle corrections").tag(CoachingStyle.gentle)
            Text("Direct corrections").tag(CoachingStyle.direct)
        }.disabled(!settings.preferences.language.isPractised)
        if !settings.preferences.language.isPractised {
            Text("Replies follow the language you speak, so there is nothing to correct and no Help Me Say This.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Toggle(
            "Use a custom speech speed",
            isOn: Binding(
                get: { settings.preferences.speed != nil }, set: { settings.preferences.speed = $0 ? 1 : nil }))
        if settings.preferences.speed != nil {
            HStack {
                Slider(
                    value: Binding(
                        get: { settings.preferences.speed ?? 1 }, set: { settings.preferences.speed = $0 }),
                    in: ConversationPreferences.speedRange,
                    step: 0.05
                )
                .accessibilityLabel("Conversation speech speed")
                Text(String(format: "%.2f×", settings.preferences.speed ?? 1)).monospacedDigit().frame(width: 60)
            }
        }
    }
}
