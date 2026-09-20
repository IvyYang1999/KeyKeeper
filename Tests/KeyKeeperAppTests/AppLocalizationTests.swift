import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

final class AppLocalizationTests: XCTestCase {
    func testActivityAndPermissionCopyHasChineseTranslation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #"L\("([^"\\]*)"\)"#)
        for file in ["ActivityPage", "ActivityDetailViews", "ActivityNavigation", "PermissionPage"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/\(file).swift"), encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let key = (source as NSString).substring(with: match.range(at: 1))
                XCTAssertNotEqual(AppL10n.render(key, language: "zh-Hans"), key, "\(file): \(key)")
            }
        }
        for key in ["{0} records", "{0} · {1} · {2}. Only this approval will be removed. It does not erase copies already received or revoke other approvals."] {
            XCTAssertNotNil(AppL10n.chinese[key], key)
        }
    }
    func testSourceImportCopyAndErrorsAreTranslated() {
        let keys = ["Save a source candidate to KeyKeeper?", "Python symbol: {0}",
            "Python source · up to 1 MiB. Only the selected string literal or environment default is extracted after approval. Source code is never executed. This is a candidate, not a verified runtime or provider credential. The original is retained; no value is shown.",
            ClipboardSaveError.invalidSource.errorDescription!, ClipboardSaveError.unsupportedSource.errorDescription!,
            ClipboardSaveError.sourceParserUnavailable.errorDescription!]
        for key in keys { XCTAssertNotNil(AppL10n.chinese[key], key) }
    }
    func testBrowserSessionStaticCopyHasChineseTranslation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/BrowserSessionViews.swift"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"L\("([^"\\]*)"\)"#)
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let key = (source as NSString).substring(with: match.range(at: 1))
            XCTAssertNotNil(AppL10n.chinese[key], key)
        }
        XCTAssertNotNil(AppL10n.chinese["Profile label: {0} · {1} Cookies"])
    }
    func testStorageCreationAndRecoveryErrorsAreTranslatedWithoutSecretInterpolation() {
        let errors: [any LocalizedError] = [CredentialStorageError.missingStore, CredentialStorageError.incompleteStore,
            ClipboardSaveError.valueExists, ClipboardSaveError.invalidTarget, ClipboardSaveError.staleGrants,
            ClipboardSaveError.storageUnavailable, ClipboardSaveError.metadataCommitFailed,
            ClipboardSaveError.metadataCommitRolledBack]
        for error in errors {
            let message = error.errorDescription!
            XCTAssertNotNil(AppL10n.chinese[message])
            XCTAssertNotEqual(AppL10n.render(message, language: "zh-Hans"), message)
        }
    }
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
        XCTAssertEqual(AuthorizationView.DurationChoice.allCases.map(\.rawValue),
                       ["Just this once", "While it runs", "Don't ask again"])
        for option in AuthorizationView.DurationChoice.allCases {
            XCTAssertNotEqual(AppL10n.render(option.rawValue, language: "zh-Hans"), option.rawValue, option.rawValue)
        }
    }

    /// 明文字段那一套是 0.3.2 新加的界面文案，两张字典里一条都没有，简体中文下会原样显示英文
    /// ——其中包括「把值移出钥匙串」这个破坏性确认按钮。按文件扫 L("…") 字面量，以后再漏也会红。
    func test明文字段相关文案都有中文() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #"L\("([^"\\]*)"\)"#)
        for file in ["Sources/KeyKeeperApp/CredentialDetailView.swift", "Sources/KeyKeeperApp/AddCredentialView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let key = (source as NSString).substring(with: match.range(at: 1))
                XCTAssertNotEqual(AppL10n.render(key, language: "zh-Hans"), key, "\(file): \(key)")
            }
        }
    }
}

extension AppLocalizationTests {
    /// 【曾经的 bug】yyt 2026-09-13 晚的截图：授权窗里那句范围说明是英文的。
    /// 因为那句话插了**两次**调用方名字，L() 生成的模板键是 {0} 和 {1}，而我在字典里
    /// 写成了两个 {0}，于是查不到、回落成英文。
    func test授权窗的范围说明有中文() {
        let template = "Allowing lets {0} read every key in this credential — {1} and code it runs, like its extensions and scripts; not other programs on this Mac. \u{201C}Always allow\u{201D} also covers its future sessions, until you revoke it."
        XCTAssertNotEqual(AppL10n.render(template, language: "zh-Hans"), template)
        let rendered = AppL10n.render(template, arguments: ["claude", "claude"], language: "zh-Hans")
        XCTAssertTrue(rendered.contains("claude 以及它运行的代码"), rendered)
        XCTAssertFalse(rendered.contains("{0}"), "占位符没被替换掉：\(rendered)")
        XCTAssertFalse(rendered.contains("{1}"), "占位符没被替换掉：\(rendered)")
    }
}
