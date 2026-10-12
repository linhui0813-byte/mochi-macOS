import Foundation
import MochiCore
import MochiKernel

/// How the character manager groups characters: the built-in ones first, then the user's own.
enum CharacterSection: CaseIterable {
    case builtIn, mine
    var title: String {
        switch self {
        case .builtIn: String(localized: "Built-in Characters")
        case .mine: String(localized: "My Characters")
        }
    }
}

/// The characters a setup can take its companion from: the built-ins and the user's, which the library keeps.
/// Every change is committed whole, so a failed write leaves the catalog as it was.
@MainActor struct CharacterCatalog {
    let library: LibraryController
    var all: [ConversationCharacter] { ConversationCharacter.builtins + library.library.characters }
    /// The non-empty sections, in order, holding the characters whose name or description contains `query`.
    func sections(matching query: String) -> [(section: CharacterSection, characters: [ConversationCharacter])] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = all.filter { c in
            term.isEmpty
                || [c.name, c.description, c.displayDescription].contains { $0.localizedCaseInsensitiveContains(term) }
        }
        return CharacterSection.allCases.compactMap { section in
            let characters = found.filter { ($0.isBuiltin ? CharacterSection.builtIn : .mine) == section }
            return characters.isEmpty ? nil : (section, characters)
        }
    }
    func character(id: UUID) throws -> ConversationCharacter {
        guard let value = all.first(where: { $0.id == id }) else {
            throw AppFailure("Character not found. Keep your draft and save it as a new character.")
        }
        return value
    }
    func create(_ patch: ConversationCharacter.Patch) throws -> ConversationCharacter {
        guard library.library.characters.count < ConversationCharacter.userLimit else {
            throw AppFailure(
                "You have 200 or more characters. Edit or remove an existing character before adding another.")
        }
        let c = try ConversationCharacter(name: "").applying(patch, creation: true)
        var candidate = library.library
        candidate.characters.append(c)
        try library.commit(candidate)
        return c
    }
    func update(id: UUID, revision: String, _ patch: ConversationCharacter.Patch) throws -> ConversationCharacter {
        let current = try character(id: id)
        guard !current.isBuiltin else {
            throw AppFailure("Built-in characters are read-only. Duplicate one to customize it.")
        }
        guard current.revision == revision else {
            throw AppFailure("This character changed. Your draft is kept; reload it or save as new.")
        }
        let updated = try current.applying(patch)
        if updated != current {
            var candidate = library.library
            guard let index = candidate.characters.firstIndex(where: { $0.id == id }) else {
                throw AppFailure("Character not found. Keep your draft and save it as a new character.")
            }
            candidate.characters[index] = updated
            try library.commit(candidate)
        }
        return updated
    }
    /// Removes only the character: setups that took their companion from it keep their own copy.
    func delete(id: UUID, revision: String) throws {
        let current = try character(id: id)
        guard !current.isBuiltin else { throw AppFailure("Built-in characters cannot be deleted.") }
        guard current.revision == revision else {
            throw AppFailure("This character changed. Read it again before deleting.")
        }
        var candidate = library.library
        candidate.characters.removeAll { $0.id == id }
        try library.commit(candidate)
    }
}
