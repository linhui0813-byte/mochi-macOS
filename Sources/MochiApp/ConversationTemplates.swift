import Foundation
import MochiAutomation
import MochiCore
import MochiKernel

/// One customization sheet. Instruction drafts are retained when its content changes to save-as.
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
extension AppModel {
    var displayCharacterName: String { conversation?.displayCharacterName ?? "Mochi" }
    var allTemplates: [ConversationTemplate] { ConversationTemplate.builtins + library.conversationTemplates }
    var templateCatalogRevision: String {
        // Sorted signatures avoid UI activity/locale affecting pagination.
        (try? MochiTools.signature(
            name: "template_catalog",
            arguments: [
                "templates": allTemplates.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                    ["id": $0.id.uuidString, "revision": $0.revision]
                }
            ])) ?? ""
    }
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
    func template(id: UUID) throws -> ConversationTemplate {
        guard let value = allTemplates.first(where: { $0.id == id }) else {
            throw AppFailure("Template not found. Keep your draft and save it as a new template.")
        }
        return value
    }
    func createTemplate(fields: [String: Any]) throws -> ConversationTemplate {
        guard library.conversationTemplates.count < ConversationTemplate.userLimit else {
            throw AppFailure(
                "You have 200 or more user templates. Edit or remove an existing template before adding another.")
        }
        let t = try ConversationTemplate(title: "").applying(fields, creation: true)
        var candidate = library
        candidate.conversationTemplates.append(t)
        try commitLibraryCandidate(candidate)
        return t
    }
    func updateTemplate(id: UUID, revision: String, fields: [String: Any]) throws -> ConversationTemplate {
        let current = try template(id: id)
        guard !current.isBuiltin else {
            throw AppFailure("Built-in templates are read-only. Duplicate one to customize it.")
        }
        guard current.revision == revision else {
            throw AppFailure("This template changed. Your draft is kept; reload it or save as new.")
        }
        let updated = try current.applying(fields)
        if updated != current {
            var candidate = library
            guard let index = candidate.conversationTemplates.firstIndex(where: { $0.id == id }) else {
                throw AppFailure("Template not found. Keep your draft and save it as a new template.")
            }
            candidate.conversationTemplates[index] = updated
            try commitLibraryCandidate(candidate)
        }
        return updated
    }
    func deleteTemplate(id: UUID, revision: String) throws {
        let current = try template(id: id)
        guard !current.isBuiltin else { throw AppFailure("Built-in templates cannot be deleted.") }
        guard current.revision == revision else {
            throw AppFailure("This template changed. Read it again before deleting.")
        }
        var candidate = library
        candidate.conversationTemplates.removeAll { $0.id == id }
        try commitLibraryCandidate(candidate)
    }
    /// Creates exactly the previewed snapshot; provenance does not depend on a surviving catalog entry.
    func startTemplateSnapshot(_ snapshot: ConversationTemplate, title: String? = nil) throws -> UUID {
        guard !busy, !practice, !managerOpen, instructionsID == nil, renameID == nil, permanentDeleteIDs.isEmpty else {
            throw AppFailure("Finish the current activity before starting a conversation.")
        }
        let chat = try snapshot.conversation(title: title)
        var candidate = library
        candidate.conversations.insert(chat, at: 0)
        candidate.selectedConversationID = chat.id
        try commitLibraryCandidate(candidate)
        templatePresentation = nil
        templateDraft = nil
        select(chat.id)
        historyScope = .active
        search = ""
        revealWorkspace?()
        return chat.id
    }
    func openTemplatePicker() {
        guard canOpenConversationInstructions else { return }
        templateDraft = nil
        templatePresentation = .picker
    }
    func openTemplateManager() {
        guard canOpenConversationInstructions else { return }
        templateDraft = nil
        templatePresentation = .manager
    }
    func editTemplate(_ value: ConversationTemplate?, duplicate: Bool = false) {
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
    func saveConversationAsTemplate(_ id: UUID, draft: ConversationSettingsDraft? = nil) {
        guard !busy, !practice, !managerOpen, renameID == nil, permanentDeleteIDs.isEmpty, templatePresentation == nil,
            instructionsID == nil || draft?.id == instructionsID,
            let chat = library.conversations.first(where: { $0.id == id && !$0.archived && !$0.isDeleted })
        else { return }
        if let draft { retainedInstructionsDraft = draft }
        let t = ConversationTemplate(
            title: chat.title, characterName: draft?.characterName ?? chat.characterName,
            instructions: draft?.instructions ?? chat.instructions, preferences: draft?.preferences ?? chat.preferences)
        // A nil draft name is an intentional reset, not a request to inherit the saved name.
        var copy = t
        if let draft { copy.characterName = draft.characterName }
        templateReturnTo = nil
        templateReturnDraft = nil
        templateDraft = TemplateEditorDraft(value: copy, editingID: nil, expectedRevision: nil)
        templatePresentation = .editor
    }
    /// Returning to the picker restores its customized preview; manager previews are re-selected from the live catalog.
    func closeTemplateEditor() {
        templateDraft = templateReturnTo == .picker ? templateReturnDraft : nil
        templatePresentation = templateReturnTo
        templateReturnTo = nil
        templateReturnDraft = nil
    }
    func executeTemplateTool(_ name: MochiToolName, arguments: [String: Any]) throws -> [String: Any] {
        let request = try MochiTools.decode(TemplateArguments.self, from: arguments)
        switch name {
        case .listConversationTemplates: return try listTemplates(arguments: arguments)
        case .createConversationTemplate: return try createTemplateOnce(arguments: arguments, request: request)
        case .getConversationTemplate, .updateConversationTemplate, .deleteConversationTemplate:
            guard let id = request.templateID else { throw AppFailure("A template ID is required.") }
            if name == .getConversationTemplate {
                return templateResult(["template": try template(id: id).representation()])
            }
            guard let revision = request.expectedTemplateRevision else {
                throw AppFailure("Read the template revision first.")
            }
            if name == .updateConversationTemplate {
                return templateResult([
                    "template": try updateTemplate(id: id, revision: revision, fields: arguments).representation()
                ])
            }
            try deleteTemplate(id: id, revision: revision)
            return templateResult(["deleted_template_id": id.uuidString], untrusted: [])
        default: throw AppFailure("This is not a template action.")
        }
    }
    private static let templateFields = [
        "template.title", "template.description", "template.character_name", "template.instructions",
    ]
    /// `untrusted` names the fields of `fields` that hold library text; by default those of one `template`.
    /// `catalogRevision` lets a caller that builds many candidate responses compute it once.
    private func templateResult(
        _ fields: [String: Any], untrusted: [String]? = nil,
        catalogRevision: String? = nil
    ) -> [String: Any] {
        fields.merging([
            "ok": true, "revision": controlRevision, "catalog_revision": catalogRevision ?? templateCatalogRevision,
            "untrusted_fields": untrusted ?? Self.templateFields,
        ]) { _, new in new }
    }
    private func listTemplates(arguments: [String: Any]) throws -> [String: Any] {
        let list = try MochiTools.decode(TemplateListArguments.self, from: arguments)
        let catalogRevision = templateCatalogRevision
        if let expected = list.expectedCatalogRevision, expected != catalogRevision {
            throw AppFailure("Template catalog changed. Restart listing from offset 0.")
        }
        let query = (list.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = list.origin ?? "all"
        let values = allTemplates.filter {
            (origin == "all" || ($0.isBuiltin ? "built_in" : "user") == origin)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.description.localizedCaseInsensitiveContains(query))
        }.sorted {
            if $0.isBuiltin != $1.isBuiltin { return $0.isBuiltin }
            if $0.title != $1.title { return $0.title.utf8.lexicographicallyPrecedes($1.title.utf8) }
            return $0.id.uuidString < $1.id.uuidString
        }
        let untrusted = ["templates.title", "templates.description", "templates.character_name"]
        func page(_ items: [[String: Any]], next: Int?) -> [String: Any] {
            templateResult(
                ["templates": items, "next_offset": next.map { $0 as Any } ?? NSNull()], untrusted: untrusted,
                catalogRevision: catalogRevision)
        }
        let offset = min(list.offset ?? 0, values.count)
        let limit = list.limit ?? 30
        var items: [[String: Any]] = []
        var index = offset
        while index < values.count && items.count < limit {
            let item = values[index].representation(includeInstructions: false)
            if try JSONSerialization.data(withJSONObject: page(items + [item], next: index + 1)).count >= 110000 {
                break
            }
            items.append(item)
            index += 1
        }
        return page(items, next: index < values.count ? index : nil)
    }
    /// A retried request with the same key returns the first result instead of creating a duplicate.
    private func createTemplateOnce(arguments: [String: Any], request: TemplateArguments) throws -> [String: Any] {
        let signature = try MochiTools.signature(
            name: MochiToolName.createConversationTemplate.rawValue, arguments: arguments)
        if let key = request.idempotencyKey, let previous = automation.templateCreations[key] {
            guard previous.signature == signature else {
                throw AppFailure("This idempotency_key was already used for a different template.")
            }
            return templateResult(["template": previous.template, "replayed": true])
        }
        let template = try createTemplate(fields: arguments).representation()
        if let key = request.idempotencyKey { automation.templateCreations.insert((signature, template), for: key) }
        return templateResult(["template": template])
    }
}
