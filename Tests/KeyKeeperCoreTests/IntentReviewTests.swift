import XCTest
@testable import KeyKeeperCore

final class IntentReviewTests: XCTestCase {
    private func input(id: String = "vercel", label: String = "Vercel", intent: UsageIntent?, expires: String? = nil,
                       security: SecurityLevel? = nil, duration: RequestedDuration? = nil) -> IntentReviewInput {
        IntentReviewInput(credentialId: id, credentialLabel: label, fieldNames: ["token"], callerName: "codex",
                          intent: intent, expires: expires, requestedSecurity: security, requestedDuration: duration)
    }

    func test一次性用途却要后台_判夸大并建议strict() {
        let review = IntentRules.review(input(intent: .init(purpose: "deploy once", frequency: .once, background: true), security: .standard))
        XCTAssertEqual(review.verdict, .inflated)
        XCTAssertTrue(review.findings.contains(.backgroundForOneOff))
        XCTAssertEqual(review.suggestedSecurity, .strict)
    }

    func test定时后台用途要standard_只提醒没过期日() {
        let cron = UsageIntent(purpose: "nightly backup", expectedCaller: "cron", frequency: .scheduled, background: true)
        let review = IntentRules.review(input(intent: cron, security: .standard, duration: .always))
        XCTAssertEqual(review.verdict, .fine)
        XCTAssertEqual(review.findings, [.noExpiryForBackground])
        XCTAssertNil(review.suggestedSecurity)
        XCTAssertNil(review.suggestedDuration)
        let withExpiry = IntentRules.review(input(intent: cron, expires: "2026-12-31", security: .standard, duration: .always))
        XCTAssertEqual(withExpiry.findings, [])
    }

    func test偶尔用却要always_建议一小时() {
        let review = IntentRules.review(input(intent: .init(purpose: "deploys when asked", frequency: .occasional, background: false), duration: .always))
        XCTAssertTrue(review.findings.contains(.alwaysWithoutRecurringUse))
        XCTAssertEqual(review.suggestedDuration, .thisRun)
        XCTAssertEqual(review.verdict, .inflated)
        let once = IntentRules.review(input(intent: .init(purpose: "one deploy", frequency: .once, background: false), duration: .always))
        XCTAssertEqual(once.suggestedDuration, .once)
    }

    func test名字像生产或root的凭据要后台_单独点名() {
        let cron = UsageIntent(purpose: "rotate", frequency: .scheduled, background: true)
        let review = IntentRules.review(input(id: "aws-prod-root", label: "AWS", intent: cron, expires: "2027-01-01", security: .standard))
        XCTAssertEqual(review.findings, [.sensitiveCredentialBackground])
        XCTAssertEqual(review.suggestedSecurity, .strict)
        XCTAssertTrue(IntentRules.looksSensitive("Production DB"))
        XCTAssertFalse(IntentRules.looksSensitive("vercel-preview"))
    }

    func test没声明用途_只要一次不说话_要更多才提醒() {
        XCTAssertEqual(IntentRules.review(input(intent: nil)).findings, [])
        XCTAssertEqual(IntentRules.review(input(intent: nil, duration: .once)).findings, [])
        let hour = IntentRules.review(input(intent: nil, duration: .oneHour))
        XCTAssertEqual(hour.findings, [.noIntentDeclared])
        XCTAssertEqual(hour.verdict, .fine, "没声明不等于夸大")
        let background = IntentRules.review(input(intent: nil, security: .standard))
        XCTAssertTrue(background.findings.contains(.backgroundForOneOff))
        XCTAssertFalse(background.findings.contains(.noIntentDeclared), "同一件事不说两遍")
    }

    func test用途声明按敌意文本处理() {
        let raw = UsageIntent(purpose: "  deploy\u{200B}\nnow\u{202E} " + String(repeating: "x", count: 300),
                              expectedCaller: "\u{0007}cron", frequency: .once, background: false)
        let clean = raw.sanitized()!
        XCTAssertTrue(clean.purpose.hasPrefix("deploy now x"))
        XCTAssertEqual(clean.purpose.count, UsageIntent.purposeLimit)
        XCTAssertEqual(clean.expectedCaller, "cron")
        XCTAssertNil(UsageIntent(purpose: " \u{200B} ", frequency: .once, background: false).sanitized())
        XCTAssertNil(UsageIntent(purpose: "x", expectedCaller: "\u{200B}", frequency: .once, background: false).sanitized()?.expectedCaller)
    }

    func test凭据元数据带用途_旧文件没有也能读() throws {
        var credential = Credential(label: "a", notes: "", links: [], fields: [:], security: .strict, created: "", updated: "")
        credential.intent = UsageIntent(purpose: "p", frequency: .scheduled, background: true, declaredBy: "codex", declaredAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(credential)
        XCTAssertEqual(try JSONDecoder().decode(Credential.self, from: data).intent, credential.intent)
        let old = Data(#"{"label":"a","notes":"","links":[],"fields":{},"security":"strict","created":"","updated":""}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Credential.self, from: old).intent)
    }

    func test请求带时长和命令行_旧客户端不带也能解() throws {
        let value = ValueRequest(credentialId: "c", fieldName: "f", sessionId: nil, requestedDuration: .oneHour, commandSummary: "vercel deploy")
        let decoded = try JSONDecoder().decode(ValueRequest.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.requestedDuration, .oneHour)
        XCTAssertEqual(decoded.commandSummary, "vercel deploy")
        let old = Data(#"{"credentialId":"c","fieldName":"f"}"#.utf8)
        let legacy = try JSONDecoder().decode(ValueRequest.self, from: old)
        XCTAssertNil(legacy.requestedDuration)
        XCTAssertNil(legacy.commandSummary)
        XCTAssertEqual(RequestedDuration(rawValue: "1h"), .oneHour)
        XCTAssertTrue(RequestedDuration.always.rank > RequestedDuration.once.rank)
    }

    func test剪贴板保存带用途_必须同create() throws {
        var request = ClipboardSaveRequest(credentialId: "c", fieldName: "f", create: false)
        request.intent = UsageIntent(purpose: "p", frequency: .once, background: false)
        XCTAssertThrowsError(try request.validate())
        request.create = true
        XCTAssertNoThrow(try request.validate())
    }
}
