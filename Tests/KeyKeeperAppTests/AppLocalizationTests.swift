import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

final class AppLocalizationTests: XCTestCase {
    func testLanguageResolutionUsesFirstSupportedLanguageAndExplicitOverride() {
        XCTAssertEqual(AppL10n.resolve(preference: "system", preferred: ["en-US", "zh-Hans-US"]), "en")
        XCTAssertEqual(AppL10n.resolve(preference: "system", preferred: ["zh-CN", "en"]), "zh-Hans")
        XCTAssertEqual(AppL10n.resolve(preference: "zh-Hans", preferred: ["en-US"]), "zh-Hans")
        XCTAssertEqual(AppL10n.resolve(preference: "en", preferred: ["zh-CN"]), "en")
        XCTAssertEqual(AppL10n.resolve(preference: "unknown", preferred: ["fr-FR"]), "en")
    }
    func testChineseEnglishAndUntrustedArgumentsAreNeverRetranslated() {
        XCTAssertEqual(AppL10n.render("Save", language: "zh-Hans"), "保存")
        XCTAssertEqual(AppL10n.render("Save", language: "en"), "Save")
        XCTAssertEqual(AppL10n.render("Unknown text", language: "zh-Hans"), "Unknown text")
        XCTAssertEqual(AppL10n.render("ID {0}", arguments: ["{1} Save 中文"], language: "zh-Hans"), "ID {1} Save 中文")
        let literal: UILocalizedString = "ID \("same-id")"
        XCTAssertEqual(literal.template, "ID {0}")
        XCTAssertEqual(literal.arguments, ["same-id"])
    }
    func testTranslationCatalogPreservesEveryPlaceholder() {
        for (key, translation) in AppL10n.chinese {
            XCTAssertFalse(translation.isEmpty)
            XCTAssertEqual(AppL10n.placeholders(in: key), AppL10n.placeholders(in: translation), key)
        }
    }
    func testBrowserPageLocalizesWithoutChangingIdentifiersOrSafetyControls() {
        let request = ClipboardSaveRequest(credentialId: "fixture-id", fieldName: "credentials-json", create: true)
        let chinese = BrowserImportPage.html(request: request, language: "zh-Hans")
        let english = BrowserImportPage.html(request: request, language: "en")
        XCTAssertTrue(chinese.contains("lang=\"zh-Hans\""))
        XCTAssertTrue(chinese.contains("粘贴一次，在 Mac 上确认。"))
        XCTAssertTrue(english.contains("Paste once. Confirm on your Mac."))
        for page in [chinese, english] {
            for invariant in ["fixture-id", "credentials-json", "type=\"password\"", "e.preventDefault()",
                              "history.replaceState", "65536", "90000", "X-KeyKeeper-Session", "credentials:'omit'"] {
                XCTAssertTrue(page.contains(invariant), invariant)
            }
        }
        let hostile = BrowserImportPage.html(request: .init(credentialId: "<script>", fieldName: "\"&"), language: "zh-Hans")
        XCTAssertTrue(hostile.contains("&lt;script&gt;"))
        XCTAssertTrue(hostile.contains("&quot;&amp;"))
    }
    func testBrowserScriptStringsCannotCloseScriptAndRoundTripExactly() throws {
        let sample = "引号 \" ' </script>\n\u{2028}\u{2029}"
        let encoded = BrowserImportPage.scriptString(sample)
        XCTAssertFalse(encoded.contains("<"))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(encoded.utf8)), sample)
    }
    func testEveryAuthorizationDurationHasTranslationButStableRawValue() {
        XCTAssertEqual(AuthorizationView.DurationOption.allCases.map(\.rawValue),
                       ["Just this once", "This terminal session", "1 hour", "Always"])
        for option in AuthorizationView.DurationOption.allCases {
            XCTAssertNotNil(AppL10n.chinese[option.rawValue])
        }
    }
}
