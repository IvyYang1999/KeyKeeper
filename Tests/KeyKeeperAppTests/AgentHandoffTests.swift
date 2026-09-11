import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class AgentHandoffTests: XCTestCase {
    private func credential(_ fields: [String: CredentialField], created: String = "2026-09-01") -> Credential {
        Credential(label: "X", notes: "", links: [], fields: fields, security: .standard, created: created, updated: created)
    }

    func test提示词包含ID命令和环境变量名但不含值() {
        let cred = credential(["api-key": CredentialField(value: "should-not-appear", secret: true)])
        let zh = AgentPromptCopy.prompt(credentialId: "openai", credential: cred, language: "zh-Hans")
        XCTAssertTrue(zh.contains("`openai`"))
        XCTAssertTrue(zh.contains("keykeeper run -c openai -- <命令>"))
        XCTAssertTrue(zh.contains("API_KEY"))
        XCTAssertTrue(zh.contains("不要向我索要这个值"))
        XCTAssertFalse(zh.contains("should-not-appear"))

        let en = AgentPromptCopy.prompt(credentialId: "openai", credential: cred, language: "en")
        XCTAssertTrue(en.contains("keykeeper run -c openai -- <command>"))
        XCTAssertTrue(en.contains("Never ask me for the value"))
    }

    func test有备注时提示词带上给Agent的备注() {
        var cred = credential(["api-key": CredentialField(value: "should-not-appear", secret: true)])
        cred.notes = "  只用于 staging 环境，额度每月 50 刀\n"
        let zh = AgentPromptCopy.prompt(credentialId: "openai", credential: cred, language: "zh-Hans")
        XCTAssertTrue(zh.contains("备注：只用于 staging 环境，额度每月 50 刀"))
        XCTAssertFalse(zh.contains("should-not-appear"))

        let en = AgentPromptCopy.prompt(credentialId: "openai", credential: cred, language: "en")
        XCTAssertTrue(en.contains("Note: 只用于 staging 环境，额度每月 50 刀"))

        cred.notes = "   "
        XCTAssertFalse(AgentPromptCopy.prompt(credentialId: "openai", credential: cred, language: "zh-Hans").contains("备注"))
    }

    func test服务账号文件的提示词带file映射() {
        let cred = credential(["credentials-json": CredentialField(secret: true, fileFormat: .serviceAccountJSON)])
        let zh = AgentPromptCopy.prompt(credentialId: "ga4", credential: cred, language: "zh-Hans")
        XCTAssertTrue(zh.contains("--file ga4:credentials-json=GOOGLE_APPLICATION_CREDENTIALS"))
        XCTAssertTrue(zh.contains("临时文件路径"))
    }

    func test最近存入按创建时间倒序且兼容两种日期格式() {
        let entries: [(id: String, credential: Credential)] = [
            ("old", credential([:], created: "2026-09-01")),
            ("clip", credential([:], created: "2026-09-11T05:20:00Z")),
            ("mid", credential([:], created: "2026-09-05")),
            ("bad", credential([:], created: "not a date")),
        ]
        XCTAssertEqual(RecentCredentials.newest(entries, limit: 3).map(\.id), ["clip", "mid", "old"])
    }

    func test日期标签今天昨天和短日期() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = RecentCredentials.date(from: "2026-09-11")!.addingTimeInterval(3600 * 12)
        XCTAssertEqual(RecentCredentials.dayLabel(for: "2026-09-11", now: now, calendar: calendar, language: "zh-Hans"), "今天")
        XCTAssertEqual(RecentCredentials.dayLabel(for: "2026-09-10", now: now, calendar: calendar, language: "en"), "Yesterday")
        XCTAssertFalse(RecentCredentials.dayLabel(for: "2026-09-01", now: now, calendar: calendar, language: "zh-Hans").isEmpty)
    }
}
