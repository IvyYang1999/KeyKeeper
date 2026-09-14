import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// 【安全审计 2026-09-13】同 UID 进程可以：connect → fork 一个兄弟进程持有连接 → 自己
/// exec 成某个受信任 App 里的二进制。服务端是在 accept **之后**才用 proc_pidpath 解析身份
/// 的，于是算出来的指纹是那个受信任 App 的，而持有连接、拿到值的是攻击者。审计员用两个
/// C 程序实测复现过这条链。
///
/// 根治办法是别用「现在这个 pid 长什么样」做身份，改用连接时的 audit token 走 SecCode
/// 校验。这一层先把「什么算已核实的身份」定下来，并保证没核实的身份匹配不到任何授权。
final class VerifiedCallerIdentityTests: XCTestCase {
    func test已核实与未核实的指纹形态() {
        let verified = CallerSubject(kind: .app,
            fingerprint: "app:team=ABCDE12345:bundle=com.example.agent:signing=com.example.agent",
            displayName: "Agent", detail: "")
        XCTAssertTrue(verified.isVerifiedCodeIdentity)

        for raw in ["unverified:pid=123", "unverified:token-unavailable", "unverified:invalid-signature"] {
            let subject = CallerSubject(kind: .executable, fingerprint: raw, displayName: "?", detail: "")
            XCTAssertFalse(subject.isVerifiedCodeIdentity, raw)
        }
    }

    /// 没核实的身份不能匹配任何授权——否则「未核实」就成了一个人人可用的通配符。
    func test未核实的身份匹配不到授权() throws {
        let store = ApprovalStore.inMemory()
        XCTAssertThrowsError(try store.add(Approval(subject: .init(fingerprint: "unverified:pid=123", displayName: "?"),
                                                    target: .credential(id: "openai", fields: nil), duration: .always)))
        XCTAssertNil(try store.valid(credentialId: "openai", field: "k", fingerprint: "unverified:pid=123", terminalSession: nil))
    }

    /// 三档，不是两档。yyt 的 Agent 大多是未签名的本地程序（那个 Electron 控制台就是），
    /// 如果「没有有效签名」一律等于「永远匹配不到授权」，等于让他每次调用都点一遍——正是
    /// 他今天抱怨的事。未签名但**能在连接时定位到可执行文件**的，仍然是一个和连接绑定的
    /// 身份（exec 掉包偷不走它），只是保证更弱，弹窗上要说清楚。
    func test三档身份() {
        XCTAssertEqual(
            CallerSubject.fingerprint(validSignature: true, teamIdentifier: "ABCDE12345",
                                      bundleIdentifier: "com.example.agent", signingIdentifier: "sig",
                                      mainExecutablePath: "/Applications/A.app/Contents/MacOS/A"),
            "app:team=ABCDE12345:bundle=com.example.agent:signing=sig")

        // 未签名：按连接时的可执行文件路径成身份
        let unsigned = CallerSubject.fingerprint(validSignature: false, teamIdentifier: nil,
                                                 bundleIdentifier: "com.darkconstant.console",
                                                 signingIdentifier: nil,
                                                 mainExecutablePath: "/Applications/Console.app/Contents/MacOS/Console")
        XCTAssertTrue(unsigned.hasPrefix("unsigned:path="), unsigned)
        XCTAssertFalse(unsigned.contains("/Applications"), "路径要哈希掉，指纹不该泄露磁盘布局")
        XCTAssertTrue(CallerSubject(kind: .executable, fingerprint: unsigned, displayName: "", detail: "").isVerifiedCodeIdentity,
                      "未签名但连接时可定位的身份，仍然可以持有授权")

        // 同一个路径永远是同一个指纹；不同路径不同指纹
        XCTAssertEqual(unsigned, CallerSubject.fingerprint(validSignature: false, teamIdentifier: nil,
                                                           bundleIdentifier: nil, signingIdentifier: nil,
                                                           mainExecutablePath: "/Applications/Console.app/Contents/MacOS/Console"))
        XCTAssertNotEqual(unsigned, CallerSubject.fingerprint(validSignature: false, teamIdentifier: nil,
                                                              bundleIdentifier: nil, signingIdentifier: nil,
                                                              mainExecutablePath: "/tmp/evil"))

        // 什么都定位不到：只能是未核实
        let nothing = CallerSubject.fingerprint(validSignature: false, teamIdentifier: nil,
                                                bundleIdentifier: nil, signingIdentifier: nil,
                                                mainExecutablePath: nil)
        XCTAssertTrue(nothing.hasPrefix(CallerSubject.unverifiedPrefix), nothing)
    }

    /// 签名信息齐全才算数：缺 team 或缺 bundle 都不能拼出一个「已核实」的指纹。
    func test签名信息不全时不算已核实() {
        XCTAssertNil(CallerSubject.verifiedFingerprint(teamIdentifier: nil, bundleIdentifier: "com.example.app", signingIdentifier: "x"))
        XCTAssertNil(CallerSubject.verifiedFingerprint(teamIdentifier: "ABCDE12345", bundleIdentifier: nil, signingIdentifier: "x"))
        XCTAssertEqual(
            CallerSubject.verifiedFingerprint(teamIdentifier: "ABCDE12345", bundleIdentifier: "com.example.app", signingIdentifier: "sig"),
            "app:team=ABCDE12345:bundle=com.example.app:signing=sig")
    }
}
