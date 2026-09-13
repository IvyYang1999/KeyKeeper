import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

@MainActor
final class CallerNameAndTierTests: XCTestCase {
    /// 【独立审计 2026-09-13】保存、登录态授权窗和菜单栏里的待批准项，调用方名字用的是只去控制字符的
    /// 弱过滤：私用区字符原样画出来，换行被直接吞掉，两行拼成一个名字。授权窗用强过滤，这里要一样。
    func test保存和菜单栏里的调用方名字用强过滤() {
        let raw = "Codex\u{E000}Helper\nApproved"
        let name = TrustPromptModel.sanitizedCaller(raw)
        XCTAssertFalse(name.unicodeScalars.contains { $0.value == 0xE000 }, name)
        XCTAssertEqual(name, CallerStatedReason.printableLine(raw, limit: 80))
        XCTAssertEqual(TrustPromptModel.sanitizedCaller(" \u{200B} "), L("Unknown Caller"))
    }

    /// 【2026-09-13 修信使问题时引入】调用方改由 CLI 上游认出来之后，指纹多了 `app:team=unsigned:`、
    /// `script:`、`executable:` 几种形态。档位只认 `unsigned:` 前缀，于是这些**没签名**的调用方全被
    /// 标成「已签名」，还配着「签名核对无误」的说明。
    func test上游调用方的档位不虚标() {
        func tier(_ fingerprint: String) -> CallerAssurance {
            CallerAssurance.of(CallerSubject(kind: .app, fingerprint: fingerprint, displayName: "x", detail: ""))
        }
        XCTAssertEqual(tier("app:team=unsigned:bundle=com.example.a:signing=x"), .unsigned)
        XCTAssertEqual(tier("script:sha256=abc"), .unsigned)
        XCTAssertEqual(tier("executable:sha256=abc"), .unsigned)
        XCTAssertEqual(tier("app:team=ABCDE12345:bundle=com.example.a:signing=x"), .signed)
    }
}

extension CallerNameAndTierTests {
    /// 【独立审计第二轮 · high】经 CLI 转来的调用方，身份其实是它所在的终端或 app，窗口却按「已签名」写
    /// 「只有它，本机别的程序蹭不到」——那个终端里跑的任何程序都算它。
    func test经CLI转来的身份不冒充已签名() throws {
        let app = CallerSubject(kind: .app, fingerprint: "app:team=H7V7XYVQ7D:bundle=com.googlecode.iterm2:signing=com.googlecode.iterm2",
                                displayName: "com.googlecode.iterm2", detail: "")
        let relayed = CallerIdentityResolver.courierUpstream(app)
        XCTAssertEqual(CallerAssurance.of(relayed), .relayed)
        XCTAssertFalse(CallerAssurance.relayed.isReassuring)
        let scope = CallerAssurance.relayed.scope(caller: "iTerm2", wholeCredential: true)
        let en = AppL10n.render(scope.template, arguments: scope.arguments, language: "en")
        XCTAssertFalse(en.contains("not other programs"), en)
        XCTAssertTrue(en.contains("anything started inside it"), en)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/IPCServer.swift"), encoding: .utf8)
        XCTAssertTrue(server.contains("StrictAuthorizationPolicy.refusal("), "认不出的调用方在弹窗前就拒绝")
    }
}
