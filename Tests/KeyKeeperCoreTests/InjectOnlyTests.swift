import XCTest
@testable import KeyKeeperCore

/// yyt 2026-09-14：「`keykeeper get` 对 Agent 的 Bash 工具不是终端，是管道——值就回到上下文里了」。
/// 凭据可以标成「只能注入、不能读出」：值只经我们自己的 CLI 的 `run` 进子进程环境，`get`、SDK、
/// 直接说 IPC 的程序一律拒绝。Agent 新建的凭据默认如此；人可以在 App 里关掉。
final class InjectOnlyTests: XCTestCase {
    private func credential(injectOnly: Bool?) -> Credential {
        Credential(label: "Stripe", notes: "", links: [], fields: ["secret-key": .init(secret: true)], security: .strict,
                   created: "", updated: "", injectOnly: injectOnly)
    }
    private let viaCLI = CallerIdentity(peerPID: 1, subject: CallerSubject(kind: .app, fingerprint: CallerSubject.relayedPrefix + "app:unsigned:path=x", displayName: "codex", detail: ""))
    private let direct = CallerIdentity(peerPID: 1, subject: CallerSubject(kind: .executable, fingerprint: "unsigned:path=y", displayName: "python3", detail: ""))

    func test只注入的凭据_只有经自家CLI的run能拿到值() {
        let cred = credential(injectOnly: true)
        XCTAssertNil(InjectOnlyPolicy.refusal(credential: cred, purpose: .inject, caller: viaCLI), "run 经 CLI：放行")
        XCTAssertNotNil(InjectOnlyPolicy.refusal(credential: cred, purpose: .read, caller: viaCLI), "get 经 CLI：拒绝")
        XCTAssertNotNil(InjectOnlyPolicy.refusal(credential: cred, purpose: nil, caller: viaCLI), "老客户端没说用途：拒绝")
        XCTAssertNotNil(InjectOnlyPolicy.refusal(credential: cred, purpose: .inject, caller: direct), "自称 inject 但没经过我们的 CLI：拒绝")
        let message = InjectOnlyPolicy.refusal(credential: cred, purpose: .read, caller: viaCLI)!
        XCTAssertTrue(message.contains("keykeeper run") && message.contains("KeyKeeper"), message)
    }

    func test没标或标了false_照旧() {
        XCTAssertNil(InjectOnlyPolicy.refusal(credential: credential(injectOnly: nil), purpose: .read, caller: direct))
        XCTAssertNil(InjectOnlyPolicy.refusal(credential: credential(injectOnly: false), purpose: nil, caller: direct))
        XCTAssertFalse(credential(injectOnly: nil).isInjectOnly, "旧凭据默认可读出，不弄坏现有脚本")
    }

    func test模型和协议往返_旧客户端不带用途也能解() throws {
        let cred = credential(injectOnly: true)
        XCTAssertEqual(try JSONDecoder().decode(Credential.self, from: JSONEncoder().encode(cred)).injectOnly, true)
        let request = ValueRequest(credentialId: "c", fieldName: "f", sessionId: nil, purpose: .inject)
        XCTAssertEqual(try JSONDecoder().decode(ValueRequest.self, from: JSONEncoder().encode(request)).purpose, .inject)
        XCTAssertNil(try JSONDecoder().decode(ValueRequest.self, from: Data(#"{"credentialId":"c","fieldName":"f"}"#.utf8)).purpose)
        XCTAssertEqual(ValueErrorCode(rawValue: "injectOnly"), .injectOnly)
    }
}
