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
    func saveConversationAsTemplate(_ id: UUID, draft: ConversationSettingsDraft? = nil) {
        guard !busy, !practice, !history.isEditing, customization.templatePresentation == nil,
            customization.instructionsID == nil || draft?.id == customization.instructionsID,
            let chat = library.conversations.first(where: { $0.id == id && !$0.archived && !$0.isDeleted })
        else { return }
        let t = ConversationTemplate(
            title: chat.title, characterName: draft?.characterName ?? chat.characterName,
            instructions: draft?.instructions ?? chat.instructions, preferences: draft?.preferences ?? chat.preferences)
        // A nil draft name is an intentional reset, not a request to inherit the saved name.
        var copy = t
        if let draft { copy.characterName = draft.characterName }
        customization.editNewTemplate(copy, retaining: draft)
    }
}
