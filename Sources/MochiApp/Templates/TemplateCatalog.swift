import Foundation
import MochiCore
import MochiKernel

/// The templates a conversation can start from: the built-ins and the user's, which the library keeps.
/// Every change is committed whole, so a failed write leaves the catalog as it was.
@MainActor struct TemplateCatalog {
    let library: LibraryController
    var all: [ConversationTemplate] { ConversationTemplate.builtins + library.library.conversationTemplates }
    func template(id: UUID) throws -> ConversationTemplate {
        guard let value = all.first(where: { $0.id == id }) else {
            throw AppFailure("Template not found. Keep your draft and save it as a new template.")
        }
        return value
    }
    func create(_ patch: ConversationTemplate.Patch) throws -> ConversationTemplate {
        guard library.library.conversationTemplates.count < ConversationTemplate.userLimit else {
            throw AppFailure(
                "You have 200 or more user templates. Edit or remove an existing template before adding another.")
        }
        let t = try ConversationTemplate(title: "").applying(patch, creation: true)
        var candidate = library.library
        candidate.conversationTemplates.append(t)
        try library.commit(candidate)
        return t
    }
    func update(id: UUID, revision: String, _ patch: ConversationTemplate.Patch) throws -> ConversationTemplate {
        let current = try template(id: id)
        guard !current.isBuiltin else {
            throw AppFailure("Built-in templates are read-only. Duplicate one to customize it.")
        }
        guard current.revision == revision else {
            throw AppFailure("This template changed. Your draft is kept; reload it or save as new.")
        }
        let updated = try current.applying(patch)
        if updated != current {
            var candidate = library.library
            guard let index = candidate.conversationTemplates.firstIndex(where: { $0.id == id }) else {
                throw AppFailure("Template not found. Keep your draft and save it as a new template.")
            }
            candidate.conversationTemplates[index] = updated
            try library.commit(candidate)
        }
        return updated
    }
    func delete(id: UUID, revision: String) throws {
        let current = try template(id: id)
        guard !current.isBuiltin else { throw AppFailure("Built-in templates cannot be deleted.") }
        guard current.revision == revision else {
            throw AppFailure("This template changed. Read it again before deleting.")
        }
        var candidate = library.library
        candidate.conversationTemplates.removeAll { $0.id == id }
        try library.commit(candidate)
    }
}
