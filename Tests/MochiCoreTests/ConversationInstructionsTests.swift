import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

final class ConversationInstructionsTests: XCTestCase {
    func testLegacyDefaultsAndRoundtrip() throws {
        var chat = Conversation()
        chat.instructions = "Interview me"
        chat.preferences.speed = 0.8
        chat.preferences.coaching = .direct
        let data = try JSONEncoder().encode(chat)
        let restored = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(restored.instructions, "Interview me")
        XCTAssertEqual(restored.preferences.speed, 0.8)
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "instructions")
        legacy.removeValue(forKey: "preferences")
        let old = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.instructions, "")
        XCTAssertNil(old.preferences.speed)
    }

}

extension ConversationInstructionsTests {
    func testOversizedInstructionsPreservedOnLoadSaveAndImport() throws {
        var library = Library()
        var chat = Conversation()
        chat.instructions = String(repeating: "x", count: 8001)
        library.conversations = [chat]
        try library.validate()
        let root = TestScratch.folder("mochi-invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        try store.prepare()
        try JSONEncoder().encode(library).write(to: store.file)
        XCTAssertEqual(try store.load().conversations[0].instructions, chat.instructions)
        try store.save(library)
        let package = root.appendingPathComponent("backup.mochilibrary")
        try LibraryBackup.write(library, from: root, to: package)
        XCTAssertEqual(try LibraryBackup.read(package).conversations[0].instructions, chat.instructions)
        XCTAssertThrowsError(try ConversationInstructions.validate(chat.instructions))
    }
}
