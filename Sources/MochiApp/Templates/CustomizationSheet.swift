import Foundation
import MochiCore
import MochiKernel

enum TemplatePresentation: String { case picker, manager, editor }
struct ConversationSettingsDraft {
    var id: UUID
    var instructions: String
    var characterName: String?
    var preferences: ConversationPreferences
}
struct TemplateEditorDraft {
    var value: ConversationTemplate
    var editingID: UUID?
    var expectedRevision: String?
}

/// The one customization sheet the workspace shows: a conversation's instructions, or the template picker,
/// manager or editor. Instruction drafts are retained when the sheet's content changes to save-as, and the
/// editor remembers what it was opened from, so closing it returns there.
struct CustomizationSheet {
    /// The conversation whose instructions are open.
    var instructionsID: UUID?
    var retainedInstructionsDraft: ConversationSettingsDraft?
    var templatePresentation: TemplatePresentation?
    var templateDraft: TemplateEditorDraft?
    private(set) var templateReturnTo: TemplatePresentation?
    private(set) var templateReturnDraft: TemplateEditorDraft?

    var isPresented: Bool { instructionsID != nil || templatePresentation != nil }
    /// Picker starts need only valid copied settings (as MCP instantiation does); editors and the manager need a writable template.
    var templateDraftIssue: String? {
        guard let draft = templateDraft else { return String(localized: "Choose a template or create one.") }
        do {
            if templatePresentation == .picker {
                _ = try draft.value.conversation()
            } else {
                try draft.value.validateForWrite()
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
    /// Edits `value`, or a new template when nil. A built-in or a duplicate becomes a new template with its own identity.
    mutating func editTemplate(_ value: ConversationTemplate?, duplicate: Bool = false) {
        templateReturnTo = templatePresentation
        templateReturnDraft = templateDraft
        var t = value ?? ConversationTemplate(title: "")
        let editing = value != nil && !duplicate && !t.isBuiltin
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
}
