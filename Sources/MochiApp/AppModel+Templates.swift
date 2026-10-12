import Foundation
import MochiCore
import MochiKernel

/// Starting conversations from templates and opening the customization sheet, within the current activity.
extension AppModel {
    var templates: TemplateCatalog { TemplateCatalog(library: libraryController) }
    /// Creates exactly the previewed snapshot; provenance does not depend on a surviving catalog entry.
    func startTemplateSnapshot(_ snapshot: ConversationTemplate, title: String? = nil) throws -> UUID {
        guard !busy, !practice, !history.isEditing, customization.instructionsID == nil else {
            throw AppFailure("Finish the current activity before starting a conversation.")
        }
        let chat = try snapshot.conversation(title: title)
        var candidate = library
        candidate.conversations.insert(chat, at: 0)
        candidate.selectedConversationID = chat.id
        try commitLibraryCandidate(candidate)
        customization.closeTemplates()
        select(chat.id)
        history.scope = .active
        history.query = ""
        revealWorkspace?()
        return chat.id
    }
    func openTemplatePicker() {
        guard canOpenConversationInstructions else { return }
        customization.showTemplates(.picker)
    }
    func openTemplateManager() {
        guard canOpenConversationInstructions else { return }
        customization.showTemplates(.manager)
    }
    /// Saves the editor's draft over the template it edits, or as a new one, then closes the editor. Every setting
    /// the editor shows is saved: replacing changes what differs from the stored template, including a cleared one.
    func saveTemplateDraft(asNew: Bool) throws {
        guard let draft = customization.templateDraft else { return }
        let value = draft.value
        if draft.editingID != nil && !asNew, let id = draft.editingID, let revision = draft.expectedRevision {
            let patch = ConversationTemplate.Patch(
                title: value.title, description: value.description,
                settings: ConversationSettingsPatch(changing: try templates.template(id: id), to: value))
            _ = try templates.update(id: id, revision: revision, patch)
        } else {
            let patch = ConversationTemplate.Patch(
                title: value.title, description: value.description,
                settings: ConversationSettingsPatch(changing: ConversationTemplate(title: ""), to: value))
            _ = try templates.create(patch)
        }
        customization.closeTemplateEditor()
    }
    /// The template the open conversation started from, while the conversation is still empty and the template
    /// exists, so the empty conversation can say what it is for.
    var starterTemplate: ConversationTemplate? {
        guard writableConversation, let chat = conversation, chat.messages.isEmpty, let id = chat.sourceTemplateID
        else { return nil }
        return templates.all.first { $0.id == id }
    }
    func saveConversationAsTemplate(_ id: UUID, draft: ConversationSettingsDraft? = nil) {
        guard !busy, !practice, !history.isEditing, customization.templatePresentation == nil,
            customization.characterPresentation == nil,
            customization.instructionsID == nil || draft?.id == customization.instructionsID,
            let chat = library.conversations.first(where: { $0.id == id && !$0.archived && !$0.isDeleted })
        else { return }
        // An unsaved draft wins whole, including what it cleared: a nil name there is a reset, not "inherit".
        var t = ConversationTemplate(title: chat.title)
        if let draft { t.adoptSettings(from: draft) } else { t.adoptSettings(from: chat) }
        customization.editNewTemplate(t, retaining: draft)
    }
}
