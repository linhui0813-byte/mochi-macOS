import MochiCore
import XCTest

@testable import MochiApp

final class ToolArgumentTests: XCTestCase {
    func testPatchFromToolArguments() throws {
        let patch = try ConversationSettingsPatch(toolArguments: ["clear_character_name": true, "speed": 1.2])
        XCTAssertEqual(patch, ConversationSettingsPatch(characterName: .clear, speed: .set(1.2)))
        XCTAssertTrue(try ConversationSettingsPatch(toolArguments: [:]).isEmpty)
    }
    func testTemplatePatchFromToolArguments() throws {
        let patch = try ConversationTemplate.Patch(
            toolArguments: ["title": "Interview", "description": "Practice", "clear_speed": true, "coaching": "direct"])
        XCTAssertEqual(
            patch,
            ConversationTemplate.Patch(
                title: "Interview", description: "Practice", settings: .init(speed: .clear, coaching: .direct)))
    }
}
