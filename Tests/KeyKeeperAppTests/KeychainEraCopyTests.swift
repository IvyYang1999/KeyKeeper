import XCTest
@testable import KeyKeeperApp

/// 【曾经的 bug】方案 A 回到钥匙串后，界面里还留着「vault 需要解锁」的旧文案，
/// 和「没有主密码、登录 Mac 就是解锁」的承诺矛盾（2026-09-11 UI review）。
final class KeychainEraCopyTests: XCTestCase {
    private let staleWords = ["vault", "unlock", "存储库", "解锁"]

    func test曾经的Bug登录启动与删除说明不再提vault和解锁() {
        for language in ["en", "zh-Hans"] {
            let texts = [
                AppL10n.render(SettingsCopy.launchAtLoginDetail, language: language),
                AppL10n.render(CredentialDeletionCopy.template, arguments: ["openai"], language: language),
            ]
            for text in texts {
                for word in staleWords {
                    XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\(language): \(text)")
                }
            }
        }
    }

    func test曾经的Bug未知终端有中文() {
        XCTAssertEqual(AppL10n.render("Unknown terminal", language: "zh-Hans"), "未知终端")
        XCTAssertEqual(AppL10n.render("No terminal session", language: "zh-Hans"), "无终端会话")
    }
}
