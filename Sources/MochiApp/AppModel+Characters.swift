import Foundation
import MochiCore
import MochiKernel

/// The character library: managing characters, saving a conversation's companion as one, and starting a
/// conversation with one.
extension AppModel {
    var characters: CharacterCatalog { CharacterCatalog(library: libraryController) }
    /// Characters that can be picked into a setup now: one that needs review must be fixed first.
    var pickableCharacters: [ConversationCharacter] { characters.all.filter { !$0.needsReview } }
    func openCharacterManager() {
        guard canOpenConversationInstructions else { return }
        customization.showCharacters()
    }
    /// Opens the character editor on the companion of a conversation, from its unsaved settings when given;
    /// closing the editor returns to them.
    func saveConversationAsCharacter(_ id: UUID, draft: ConversationSettingsDraft) {
        guard !busy, !practice, !history.isEditing, customization.templatePresentation == nil,
            customization.characterPresentation == nil, customization.instructionsID == id,
            library.conversations.contains(where: { $0.id == id && !$0.archived && !$0.isDeleted })
        else { return }
        let value = ConversationCharacter(
            name: draft.characterName ?? "", personality: draft.personality, voice: draft.preferences.voice)
        customization.editNewCharacter(value, retaining: draft)
    }
    /// Saves the editor's draft over the character it edits, or as a new one, then closes the editor.
    func saveCharacterDraft(asNew: Bool) throws {
        guard let draft = customization.characterDraft else { return }
        if draft.editingID != nil && !asNew, let id = draft.editingID, let revision = draft.expectedRevision {
            let patch = ConversationCharacter.Patch(changing: try characters.character(id: id), to: draft.value)
            _ = try characters.update(id: id, revision: revision, patch)
        } else {
            _ = try characters.create(
                ConversationCharacter.Patch(changing: ConversationCharacter(name: ""), to: draft.value))
        }
        customization.closeCharacterEditor()
    }
    /// A new conversation, in the user's default language, with `character` as its companion.
    @discardableResult func startConversation(with character: ConversationCharacter) throws -> UUID {
        guard !busy, !practice, !history.isEditing, customization.instructionsID == nil else {
            throw AppFailure("Finish the current activity before starting a conversation.")
        }
        guard !character.needsReview else {
            throw AppFailure("Review this character before using it.")
        }
        var chat = freshConversation()
        chat.adoptCharacter(character)
        var candidate = library
        candidate.conversations.insert(chat, at: 0)
        candidate.selectedConversationID = chat.id
        try commitLibraryCandidate(candidate)
        customization.closeCharacters()
        select(chat.id)
        history.scope = .active
        history.query = ""
        revealWorkspace?()
        return chat.id
    }
}
