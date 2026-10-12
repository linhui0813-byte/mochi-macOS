import MochiCore
import XCTest

@testable import MochiApp

/// scripts/localization.py proves the catalog covers the source; these prove the compiled translations load.
final class LocalizationTests: XCTestCase {
    static let languages = ["zh-Hans", "zh-Hant", "ja", "ko"]
    private var compiled: URL?

    /// Compiles the catalogs the way build-app.sh does, once per test.
    private func translations(_ language: String) throws -> Bundle {
        if compiled == nil {
            let output = makeTemporaryFolder("mochi-localization")
            let catalogs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Localization")
            for catalog in ["Localizable", "InfoPlist"] {
                let compile = Process()
                compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                compile.arguments = [
                    "xcstringstool", "compile", catalogs.appendingPathComponent("\(catalog).xcstrings").path,
                    "--output-directory", output.path,
                ]
                try compile.run()
                compile.waitUntilExit()
                XCTAssertEqual(compile.terminationStatus, 0, "xcstringstool could not compile \(catalog)")
            }
            compiled = output
        }
        let path = try XCTUnwrap(compiled).appendingPathComponent("\(language).lproj").path
        return try XCTUnwrap(Bundle(path: path), "\(language) was not compiled")
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

    func testEveryBuiltinTemplateIsTranslated() throws {
        for language in Self.languages {
            let bundle = try translations(language)
            for t in ConversationTemplate.builtins {
                for key in [t.title, t.description] {
                    XCTAssertNotEqual(
                        bundle.localizedString(forKey: key, value: nil, table: nil), key,
                        "\(language) has no translation for \(key)")
                }
            }
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
        // Display text is chosen per built-in; with no translation loaded it is the stored English, so a typo shows.
        for t in ConversationTemplate.builtins {
            XCTAssertEqual(t.displayTitle, t.title)
            XCTAssertEqual(t.displayDescription, t.description)
        }
        XCTAssertEqual(PracticePane.referenceKindLabel("Alloy · Codex voice"), "Alloy · Codex voice")
        XCTAssertEqual(PracticePane.referenceKindLabel(nil), "Reference")
    }
}
