import MochiKernel
import XCTest

@testable import MochiCore

final class ConversationCharacterTests: XCTestCase {
    func testBuiltinsAreFixedValidAndReserved() throws {
        let builtins = ConversationCharacter.builtins
        XCTAssertEqual(builtins.map(\.name), ["Mochi", "Alex", "Pip"])
        XCTAssertEqual(
            builtins.map(\.id.uuidString), (1...3).map { String(format: "DAF3D004-0000-4000-8000-%012d", $0) })
        XCTAssertEqual(ConversationCharacter.reservedIDs, Set(builtins.map(\.id)))
        XCTAssertTrue(ConversationCharacter.reservedIDs.isDisjoint(with: ConversationTemplate.reservedIDs))
        XCTAssertEqual(Set(builtins.map(\.revision)).count, 3)
        for character in builtins {
            XCTAssertTrue(character.isBuiltin)
            XCTAssertNoThrow(try character.validateForWrite(), character.name)
            XCTAssertFalse(character.needsReview)
            // No translation loads in tests, so the display text is the stored English; a typo in a key fails here.
            XCTAssertEqual(character.displayDescription, character.description)
            if let voice = character.voice { XCTAssertNotNil(RealtimeVoice(rawValue: voice), character.name) }
        }
        // Mochi is the default companion: Mochi's own manner and the Settings voice.
        XCTAssertEqual(builtins[0].personality, "")
        XCTAssertNil(builtins[0].voice)
        XCTAssertEqual(builtins[1].voice, "cedar")
        XCTAssertEqual(builtins[2].voice, "coral")
        // The revision is a hash of the content, so it is the same on every launch.
        let again = try JSONDecoder().decode(
            [ConversationCharacter].self, from: JSONEncoder().encode(ConversationCharacter.builtins))
        XCTAssertEqual(again.map(\.revision), builtins.map(\.revision))
    }

    func testCreatingAndEditingValidatesOnlyWhatChanges() throws {
        let blank = ConversationCharacter(name: "")
        XCTAssertThrowsError(try blank.applying(.init(), creation: true))
        XCTAssertThrowsError(try blank.applying(.init(name: "Two\nlines"), creation: true))
        XCTAssertThrowsError(try blank.applying(.init(name: "Rose", voice: .set("future_voice")), creation: true))
        let rose = try blank.applying(
            .init(name: "  Rose ", description: " Patient ", personality: " Kind and slow. ", voice: .set("sage")),
            creation: true)
        XCTAssertEqual(rose.name, "Rose")
        XCTAssertEqual(rose.description, "Patient")
        XCTAssertEqual(rose.personality, "Kind and slow.")
        XCTAssertEqual(rose.voice, "sage")
        XCTAssertEqual(try rose.applying(.init(name: "Rose")).revision, rose.revision, "No change, same revision")
        let renamed = try rose.applying(.init(name: "Grandma Rose", voice: .clear))
        XCTAssertNotEqual(renamed.revision, rose.revision)
        XCTAssertEqual(renamed.name, "Grandma Rose")
        XCTAssertNil(renamed.voice)
        XCTAssertThrowsError(
            try rose.applying(
                .init(personality: String(repeating: "x", count: ConversationPersonality.maxCharacters + 1))))
    }

    /// Imported characters keep what this version cannot use, and can still be fixed one field at a time.
    func testImportedCharactersKeepUnknownVoicesAndCanBeRepaired() throws {
        var imported = ConversationCharacter(name: "Nova", voice: "future_voice")
        XCTAssertFalse(imported.needsReview, "An unknown voice is kept, not a reason for review")
        let described = try imported.applying(.init(description: "From a newer Mochi"))
        XCTAssertEqual(described.voice, "future_voice")
        imported.personality = String(repeating: "y", count: ConversationPersonality.maxCharacters + 1)
        XCTAssertTrue(imported.needsReview)
        let partly = try imported.applying(.init(description: "Still too long a personality"))
        XCTAssertEqual(partly.personality, imported.personality)
        let fixed = try imported.applying(.init(personality: "Short now"))
        XCTAssertFalse(fixed.needsReview)
    }

    func testDecodingKeepsPlausibleVoicesAndOptionalText() throws {
        let id = UUID()
        func decode(_ voice: String) throws -> ConversationCharacter {
            try JSONDecoder().decode(
                ConversationCharacter.self,
                from: Data(
                    #"{"id":"\#(id)","revision":"r","name":"Nova","createdAt":0,"updatedAt":0\#(voice)}"#.utf8))
        }
        let minimal = try decode("")
        XCTAssertEqual(minimal.description, "")
        XCTAssertEqual(minimal.personality, "")
        XCTAssertNil(minimal.voice)
        XCTAssertEqual(try decode(#","voice":"future_voice""#).voice, "future_voice")
        XCTAssertNil(try decode(#","voice":"not a voice""#).voice)
        XCTAssertNil(try decode(#","voice":3"#).voice)
        let rose = ConversationCharacter(name: "Rose", description: "Patient", personality: "Kind", voice: "sage")
        XCTAssertEqual(try JSONDecoder().decode(ConversationCharacter.self, from: JSONEncoder().encode(rose)), rose)
    }

    func testRepresentationIsBoundedAndNamesTruncatedFields() throws {
        var character = ConversationCharacter(name: "Nova", voice: "future_voice")
        character.personality = String(repeating: "z", count: ConversationPersonality.maxCharacters + 50)
        let shown = character.representation()
        XCTAssertEqual((shown["personality"] as? String)?.count, ConversationPersonality.maxCharacters)
        XCTAssertEqual((shown["fields_truncated"] as? [String: Bool])?["personality"], true)
        XCTAssertEqual(shown["voice"] as? String, "future_voice")
        XCTAssertEqual(shown["origin"] as? String, "user")
        XCTAssertEqual(shown["needs_review"] as? Bool, true)
        XCTAssertTrue(ConversationCharacter.builtins[0].representation()["voice"] is NSNull)
        XCTAssertEqual(ConversationCharacter.builtins[0].representation()["origin"] as? String, "built_in")
    }
}
