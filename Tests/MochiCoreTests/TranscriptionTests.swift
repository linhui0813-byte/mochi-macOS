import MochiTestSupport
import XCTest

@testable import MochiCore

final class TranscriptionTests: XCTestCase {
    func testLegacyPlaceholdersDecodeAsMetadataAndNeverContext() throws {
        for text in ["Voice message (transcript unavailable)", "Voice message · awaiting transcript"] {
            let old = Message(role: "user", text: text, audio: "recording.wav")
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
            json.removeValue(forKey: "transcriptionState")
            let restored = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(restored.text, "")
            XCTAssertNil(restored.contextText)
            XCTAssertNotNil(restored.transcriptionState)
        }
        XCTAssertEqual(
            Message(role: "user", text: "An actual thought", audio: "recording.wav").contextText, "An actual thought")
        XCTAssertEqual(
            Message(role: "user", text: "Voice message (transcript unavailable)").contextText,
            "Voice message (transcript unavailable)")
    }
    func testPendingLoadBecomesInterruptedAndMigrationPreservesOriginal() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        var library = Library()
        var chat = Conversation()
        var message = Message(role: "user", text: "", audio: "recording.wav")
        message.transcriptionState = .pending
        chat.messages = [message]
        chat.helpDraft = HelpDraft(meaning: "A thought", english: "A sentence", recording: "thought.wav")
        library.conversations = [chat]
        try store.save(library)
        let before = try Data(contentsOf: store.file)
        var loaded = try store.load()
        XCTAssertEqual(loaded.conversations[0].messages[0].transcriptionState, .interrupted)
        XCTAssertTrue(loaded.referencedAudio.contains("thought.wav"))
        loaded.conversations[0].messages[0].text = "Updated"
        try store.save(loaded)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("library-before-help-transcription.json")), before)
    }
}
