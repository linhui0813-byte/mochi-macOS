import MochiCore
import MochiKernel
import SwiftUI

struct ConversationInstructionsView: View {
    @Bindable var app: AppModel
    let id: UUID
    @State private var saveError: String?
    @State private var draft: ConversationSettingsDraft
    init(app: AppModel, id: UUID) {
        self.app = app
        self.id = id
        // A draft kept while Save as Template or Save as Character was open comes back; otherwise the stored one.
        let retained = app.customization.retainedInstructionsDraft.flatMap { $0.id == id ? $0 : nil }
        let stored = app.library.conversations.first(where: { $0.id == id }).map(ConversationSettingsDraft.init)
        _draft = State(initialValue: retained ?? stored ?? ConversationSettingsDraft(id: id))
    }
    private var stored: Conversation? { app.library.conversations.first { $0.id == id } }
    /// The save's own validation, run on a copy: only what the draft changed is checked.
    private var validationError: String? {
        guard var copy = stored else { return nil }
        do {
            try ConversationSettingsPatch(changing: copy, to: draft).apply(to: &copy)
            return nil
        } catch { return (error as? AppFailure)?.message ?? String(localized: "Review these settings.") }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conversation Instructions").font(.title2).fontWeight(.semibold)
            Text(stored?.displayTitle ?? "").foregroundStyle(.secondary).lineLimit(1)
            Text(
                "Tell \((draft.characterName ?? "Mochi").bounded(characters: 80, bytes: 1024)) how you want to practise. These settings apply to future replies."
            ).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ConversationSettingsFields(
                        app: app, settings: $draft,
                        saveAsCharacter: { app.saveConversationAsCharacter(id, draft: draft) })
                }.padding(.trailing, 12)
            }
            if let error = saveError ?? validationError { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Reset to Defaults") {
                    // What a new conversation gets, including the default language from Settings.
                    draft = ConversationSettingsDraft(id: id)
                    draft.adoptSettings(from: app.freshConversation())
                    saveError = nil
                }
                Button("Save as Template…") { app.saveConversationAsTemplate(id, draft: draft) }.disabled(app.busy)
                Spacer()
                Button("Cancel") {
                    app.customization.instructionsID = nil
                    app.customization.retainedInstructionsDraft = nil
                }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let existingError = app.error
                    if app.saveConversationSettings(id, draft) {
                        app.customization.instructionsID = nil
                        app.customization.retainedInstructionsDraft = nil
                    } else {
                        saveError = app.error
                    }
                    app.error = existingError
                }.keyboardShortcut(.defaultAction).disabled(validationError != nil || app.busy)
            }
        }.padding(24).frame(width: 620, height: 640)
            .onChange(of: draft) { saveError = nil }
    }
}
