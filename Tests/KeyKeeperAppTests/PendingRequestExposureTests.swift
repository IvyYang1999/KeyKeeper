import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 【安全审计 2026-09-13】`keykeeper requests` 走的那条 IPC 完全没有鉴权闸，任何同 UID
/// 进程都能读到当前待批和排队中所有请求的**调用方指纹**——也就是「要冒充谁，指纹长什么
/// 样」这份现成的答案。
///
/// 这个列表本身是有用的（人要在终端里看有谁在等），所以不是关掉它，而是把里面**只有
/// KeyKeeper 自己需要**的那一项摘掉。
final class PendingRequestExposureTests: XCTestCase {
    func test列表里不带调用方指纹() throws {
        let summary = PendingServiceRequestSummary(
            id: "r1", credentialId: "openai", credentialLabel: "OpenAI",
            fieldNames: ["api-key"], callerDisplayName: "Agent",
            subjectFingerprint: "app:team=ABCDE12345:bundle=com.example.agent:signing=x",
            requestedAt: Date(), expiresAt: Date().addingTimeInterval(90))

        let redacted = summary.redactedForCaller()
        XCTAssertEqual(redacted.subjectFingerprint, "")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(redacted), as: UTF8.self)
            .contains("ABCDE12345"), "指纹不能出现在回给调用方的字节里")

        // 人要看的东西都还在
        XCTAssertEqual(redacted.credentialLabel, "OpenAI")
        XCTAssertEqual(redacted.callerDisplayName, "Agent")
        XCTAssertEqual(redacted.fieldNames, ["api-key"])
        XCTAssertEqual(redacted.id, "r1")
    }
}
