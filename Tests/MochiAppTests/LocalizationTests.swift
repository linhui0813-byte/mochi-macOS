import MochiCore
import XCTest

@testable import MochiApp

/// scripts/localization.py proves the catalog covers the source; these prove the built translations load.
final class LocalizationTests: XCTestCase {
    static let languages = ["zh-Hans", "zh-Hant", "ja", "ko"]

    private func translations(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle.module.path(forResource: language, ofType: "lproj"),
            "\(language) not built in \(Bundle.module.bundlePath): \(Bundle.module.localizations)")
        return try XCTUnwrap(Bundle(path: path))
    }

    func testEveryShippedLanguageTranslatesTheInterfaceAndTheMicrophonePrompt() throws {
        for language in Self.languages {
            let bundle = try translations(language)
            for key in ["Ready when you are · microphone off", "Help Me Say This", "A new conversation"] {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertNotEqual(value, key, "\(language) has no translation for \(key)")
            }
            let prompt = bundle.localizedString(forKey: "NSMicrophoneUsageDescription", value: nil, table: "InfoPlist")
            XCTAssertNotEqual(prompt, "NSMicrophoneUsageDescription", "\(language) has no microphone prompt")
        }
    }

    func testTranslatedPlaceholdersStillFormat() throws {
        for language in Self.languages {
            let format = try translations(language).localizedString(forKey: "%lld selected", value: nil, table: nil)
            XCTAssertTrue(String(format: format, 3).contains("3"), "\(language): \(format)")
        }
    }

    /// Tests run without the app's translations, so model text stays English and existing assertions hold.
    func testStoredDefaultsStayEnglishAndDisplayFollowsTheLanguage() {
        let chat = Conversation()
        XCTAssertEqual(chat.title, Conversation.untitled)
        XCTAssertEqual(chat.displayTitle, "A new conversation")
        var named = chat
        named.customTitle = true
        named.title = "A new conversation"
        XCTAssertEqual(named.displayTitle, "A new conversation")
        let restaurant = ConversationTemplate.builtins[0]
        XCTAssertEqual(restaurant.displayTitle, restaurant.title)
        XCTAssertEqual(PracticePane.referenceKindLabel("Alloy · Codex voice"), "Alloy · Codex voice")
        XCTAssertEqual(PracticePane.referenceKindLabel(nil), "Reference")
    }
}
