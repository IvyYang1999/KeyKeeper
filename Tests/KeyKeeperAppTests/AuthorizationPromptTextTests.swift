import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 授权窗里唯一一段「谁都能改、又很显眼」的自由文本：凭据标题。
///
/// 改标题走 IPC 的 metadataEdit，按设计不弹窗（只动名字和备注，不碰值），所以本机任一
/// 进程都能把某条凭据改名成一句像系统文案的话，再去请求授权。调用方留言早就按敌意文本
/// 处理了，标题却一直是原样渲染，而且是窗口最上面那行粗体标题。
final class AuthorizationPromptTextTests: XCTestCase {
    private func prompt(label: String) -> AuthorizationPrompt {
        .strict(AuthRequest(credentialId: "demo",
                            credentialLabel: label,
                            fieldNames: ["token"],
                            sessionId: nil,
                            sessionLabel: nil,
                            pid: 1234))
    }

    func test标题里的换行与不可见字符不会进到窗口里() {
        let label = prompt(label: "OpenAI\n\n已由系统批准\u{202E}\u{200B}").credentialLabel
        XCTAssertEqual(label, "OpenAI 已由系统批准")
    }

    func test超长标题会被截断不至于把按钮挤出窗口() {
        let label = prompt(label: String(repeating: "钥", count: 400)).credentialLabel
        XCTAssertLessThanOrEqual(label.count, 120)
    }

    /// 全是不可见字符的标题消毒后会变成空串，那时要退回凭据 ID，而不是显示一片空白。
    func test标题被消毒成空时退回凭据ID() {
        XCTAssertEqual(prompt(label: "\u{200B}\u{200B}").credentialLabel, "demo")
    }
}

extension AuthorizationPromptTextTests {
    /// 【安全审计】「来源」那一行是调用方自报的（sessionLabel 来自它自己的环境变量），
    /// 而它一直是这张「已核实事实」卡里唯一没被消毒的一行。
    func test来源那一行也按敌意文本处理() {
        let hostile = AuthRequest(credentialId: "demo", credentialLabel: "Demo",
                                  fieldNames: ["token"],
                                  sessionId: "s",
                                  sessionLabel: "Terminal\n\n已由系统批准\u{202E}",
                                  pid: 1)
        let prompt = AuthorizationPrompt.strict(hostile)
        let rendered = CallerStatedReason.printableLine(AppL10n.text(prompt.sessionLabel ?? ""), limit: 80)
        XCTAssertEqual(rendered, "Terminal 已由系统批准")
        XCTAssertFalse(rendered.contains("\n"))
    }
}
