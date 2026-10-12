import MochiKernel
import XCTest

@testable import MochiCore

final class GreetingsTests: XCTestCase {
    func testEveryLanguageHasSixDistinctLinesNamingTheCompanionOnce() {
        var seen: [[String]: ConversationLanguage] = [:]
        for language in ConversationLanguage.allCases where language != .match {
            for script in [Greetings.ChineseScript.simplified, .traditional]
            where script == .simplified || language == .chinese {
                let lines = Greetings.patterns(language, script: script)
                XCTAssertEqual(Set(lines).count, 6, "\(language)")
                for line in lines {
                    XCTAssertEqual(line.components(separatedBy: "{name}").count, 2, "\(language): \(line)")
                    XCTAssertFalse(line.contains("Mochi"), "Any companion can say it")
                }
                // A language that fell back to another's lines would greet in the wrong language.
                if let other = seen[lines], !(language == .chinese && other == .chinese) {
                    XCTFail("\(language) shares its greetings with \(other)")
                }
                seen[lines] = language
            }
        }
    }

    func testAGreetingIsSpokenInTheConversationsLanguageOrTheInterfaces() {
        func spoken(_ language: ConversationLanguage, _ interface: String) -> String {
            let result = Greetings.spoken(language, interface: interface)
            return "\(result.language.rawValue) \(result.script)"
        }
        XCTAssertEqual(spoken(.german, "ja"), "de simplified", "A chosen language wins")
        XCTAssertEqual(spoken(.chinese, "zh-Hant"), "zh traditional", "Chinese is written as the user reads it")
        XCTAssertEqual(spoken(.chinese, "en"), "zh simplified")
        XCTAssertEqual(spoken(.match, "ko"), "ko simplified", "Before the user speaks, the interface is the hint")
        XCTAssertEqual(spoken(.match, "zh-Hant"), "zh traditional")
        XCTAssertEqual(spoken(.match, "en"), "en simplified")
        XCTAssertEqual(spoken(.match, "eo"), "en simplified", "An interface language Mochi cannot speak")
    }

    func testANamedGreetingUsesTheLanguagesLinesAndTheName() {
        let greeting = VoiceIdentity.namedGreeting(name: "Loki", language: .japanese, excluding: [])
        XCTAssertTrue(Greetings.patterns(.japanese).contains(greeting.pattern))
        XCTAssertEqual(greeting.text, greeting.pattern.replacingOccurrences(of: "{name}", with: "Loki"))
        XCTAssertEqual(VoiceIdentity.greetings.count, 6)
        XCTAssertTrue(VoiceIdentity.greetings.allSatisfy { $0.contains("Mochi") })
    }
}
