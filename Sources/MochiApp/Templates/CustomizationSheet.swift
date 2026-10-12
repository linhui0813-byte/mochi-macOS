import Foundation
import MochiCore
import MochiKernel

enum TemplatePresentation: String { case picker, manager, editor }
enum CharacterPresentation: String { case manager, editor }
/// A conversation's settings while they are edited, before they are saved to it.
struct ConversationSettingsDraft: ConversationSettingsHolder, Equatable {
    var id: UUID
    var instructions = ""
    var characterName: String?
    var personality = ""
    var greeting = ""
    var phrases: [String] = []
    var preferences = ConversationPreferences()
}
extension ConversationSettingsDraft {
    /// The settings `chat` has now.
    init(_ chat: Conversation) {
        self.init(id: chat.id)
        adoptSettings(from: chat)
    }
}
struct TemplateEditorDraft {
    var value: ConversationTemplate
    var editingID: UUID?
    var expectedRevision: String?
}
struct CharacterEditorDraft {
    var value: ConversationCharacter
    var editingID: UUID?
    var expectedRevision: String?
}

/// The one customization sheet the workspace shows: a conversation's instructions, the template picker, manager or
/// editor, or the character manager or editor. Instruction drafts are retained when the sheet's content changes to
/// save-as, and each editor remembers what it was opened from, so closing it returns there.
struct CustomizationSheet {
    /// The conversation whose instructions are open.
    var instructionsID: UUID?
    var retainedInstructionsDraft: ConversationSettingsDraft?
    var templatePresentation: TemplatePresentation?
    var templateDraft: TemplateEditorDraft?
    private(set) var templateReturnTo: TemplatePresentation?
    private(set) var templateReturnDraft: TemplateEditorDraft?
    var characterPresentation: CharacterPresentation?
    var characterDraft: CharacterEditorDraft?
    private(set) var characterReturnTo: CharacterPresentation?

    var isPresented: Bool { instructionsID != nil || templatePresentation != nil || characterPresentation != nil }
    /// Picker starts need only valid copied settings (as MCP instantiation does); editors and the manager need a writable template.
    var templateDraftIssue: String? {
        guard let draft = templateDraft else { return String(localized: "Choose a template or create one.") }
        do {
            if templatePresentation == .picker {
                _ = try draft.value.conversation()
            } else {
                // Empty phrase rows are dropped on save, so they are no reason to refuse it.
                var value = draft.value
                value.phrases = ConversationPhrases.normalized(value.phrases)
                try value.validateForWrite()
            }
            return nil
        } catch { return AppFailure.message(for: error, fallback: "Review the settings.") }
    }
    /// Closes whatever the sheet shows, as when SwiftUI dismisses it.
    mutating func dismiss() {
        instructionsID = nil
        templatePresentation = nil
        templateDraft = nil
        retainedInstructionsDraft = nil
        characterPresentation = nil
        characterDraft = nil
        characterReturnTo = nil
    }
    mutating func showTemplates(_ presentation: TemplatePresentation) {
        templateDraft = nil
        templatePresentation = presentation
    }
    /// Leaves the picker or manager.
    mutating func closeTemplates() {
        templatePresentation = nil
        templateDraft = nil
    }
    /// The draft the picker previews for `template`: a built-in's greeting and phrases read in the interface language.
    mutating func previewTemplate(_ template: ConversationTemplate) {
        templateDraft = TemplateEditorDraft(
            value: template.withBuiltinTextTranslated(), editingID: nil, expectedRevision: template.revision)
    }
    /// Edits `value`, or a new template when nil. A built-in or a duplicate becomes a new template with its own
    /// identity; a built-in's copy reads in the interface language, since the copy is the user's own text.
    mutating func editTemplate(_ value: ConversationTemplate?, duplicate: Bool = false) {
        templateReturnTo = templatePresentation
        templateReturnDraft = templateDraft
        var t = value ?? ConversationTemplate(title: "")
        let editing = value != nil && !duplicate && !t.isBuiltin
        if let value, value.isBuiltin {
            t = value.withBuiltinTextTranslated()
            t.title = value.displayTitle
            t.description = value.displayDescription
        }
        if !editing {
            t.id = UUID()
            t.revision = UUID().uuidString
            t.createdAt = Date()
            t.updatedAt = t.createdAt
        }
        templateDraft = TemplateEditorDraft(
            value: t, editingID: editing ? t.id : nil, expectedRevision: editing ? t.revision : nil)
        templatePresentation = .editor
    }
    /// Opens the editor on a new template; closing it returns to no sheet, while `retaining` keeps the
    /// instructions draft it was made from.
    mutating func editNewTemplate(_ value: ConversationTemplate, retaining draft: ConversationSettingsDraft?) {
        if let draft { retainedInstructionsDraft = draft }
        templateReturnTo = nil
        templateReturnDraft = nil
        templateDraft = TemplateEditorDraft(value: value, editingID: nil, expectedRevision: nil)
        templatePresentation = .editor
    }
    /// Returning to the picker restores its customized preview; manager previews are re-selected from the live catalog.
    mutating func closeTemplateEditor() {
        templateDraft = templateReturnTo == .picker ? templateReturnDraft : nil
        templatePresentation = templateReturnTo
        templateReturnTo = nil
        templateReturnDraft = nil
    }

    // MARK: Characters

    mutating func showCharacters() {
        characterDraft = nil
        characterReturnTo = nil
        characterPresentation = .manager
    }
    /// Leaves the character manager.
    mutating func closeCharacters() {
        characterPresentation = nil
        characterDraft = nil
        characterReturnTo = nil
    }
    /// Edits `value`, or a new character when nil. A built-in or a duplicate becomes a new character with its own
    /// identity, its description in the interface language.
    mutating func editCharacter(_ value: ConversationCharacter?, duplicate: Bool = false) {
        characterReturnTo = characterPresentation
        var c = value ?? ConversationCharacter(name: "")
        let editing = value != nil && !duplicate && !c.isBuiltin
        if !editing {
            c.description = c.displayDescription
            c.id = UUID()
            c.revision = UUID().uuidString
            c.createdAt = Date()
            c.updatedAt = c.createdAt
        }
        characterDraft = CharacterEditorDraft(
            value: c, editingID: editing ? c.id : nil, expectedRevision: editing ? c.revision : nil)
        characterPresentation = .editor
    }
    /// Opens the editor on a new character made from a conversation's settings; closing it returns to them, with
    /// the instructions draft it was made from.
    mutating func editNewCharacter(_ value: ConversationCharacter, retaining draft: ConversationSettingsDraft?) {
        if let draft { retainedInstructionsDraft = draft }
        characterReturnTo = nil
        characterDraft = CharacterEditorDraft(value: value, editingID: nil, expectedRevision: nil)
        characterPresentation = .editor
    }
    mutating func closeCharacterEditor() {
        characterDraft = nil
        characterPresentation = characterReturnTo
        characterReturnTo = nil
    }
}
