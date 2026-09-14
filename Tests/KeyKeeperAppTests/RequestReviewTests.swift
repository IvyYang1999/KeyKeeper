import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// yyt 2026-09-14：「应该有一个独立的第三方，检查下模型的需求合不合理，避免模型夸大需求」。
@MainActor
final class RequestReviewTests: XCTestCase {
    private func identity(fingerprint: String = "unsigned:path=/usr/local/bin/codex") -> CallerIdentity {
        CallerIdentity(peerPID: 7, executablePath: "/usr/local/bin/codex", bundleIdentifier: nil,
                       subject: CallerSubject(kind: .executable, fingerprint: fingerprint, displayName: "codex", detail: ""))
    }

    private func strict(duration: RequestedDuration?, command: String? = "vercel deploy\u{200B} --prod",
                        fingerprint: String = "unsigned:path=/usr/local/bin/codex") -> AuthorizationPrompt {
        .strict(AuthRequest(credentialId: "vercel", credentialLabel: "Vercel", fieldNames: ["token"], sessionId: "s1",
                            sessionLabel: nil, pid: 7, callerIdentity: identity(fingerprint: fingerprint),
                            statedReason: .sanitize("deploy preview"), requestedDuration: duration, commandSummary: command))
    }

    private func credential(intent: UsageIntent?, expires: String? = nil) -> Credential {
        Credential(label: "Vercel", notes: "", links: [], fields: ["token": .init(secret: true)], security: .strict,
                   created: "", updated: "", expires: expires, intent: intent)
    }

    func test从请求和凭据拼出审查输入_命令行按敌意文本处理() throws {
        let approvals = ApprovalStore.inMemory()
        try approvals.add(Approval(subject: .init(fingerprint: "unsigned:path=/x", displayName: "x"),
                                   target: .credential(id: "vercel", fields: nil), duration: .always))
        let review = RequestReview.make(prompt: strict(duration: .always),
                                        credential: credential(intent: .init(purpose: "one deploy", frequency: .once, background: false)),
                                        approvals: approvals)
        XCTAssertEqual(review.input.command, "vercel deploy --prod")
        XCTAssertEqual(review.input.reason, "deploy preview")
        XCTAssertEqual(review.input.callerTier, "unsigned")
        XCTAssertEqual(review.input.requestedDuration, .always)
        XCTAssertNil(review.input.requestedSecurity, "保护方式在创建时已定，请求时不再审")
        XCTAssertEqual(review.input.history, "1 approval(s) on record for this credential")
        XCTAssertEqual(review.rules.verdict, .inflated)
        XCTAssertEqual(review.rules.suggestedDuration, .once)
        XCTAssertTrue(review.hasContent)
        XCTAssertTrue(review.keykeeperSuggestsLine!.contains("Once"), review.keykeeperSuggestsLine!)
        XCTAssertEqual(review.agentAsksLine, "Always")
        XCTAssertTrue(review.intentLine!.hasPrefix("one deploy ("), review.intentLine!)
    }

    func test什么都没要没声明_没有内容() {
        let review = RequestReview.make(prompt: strict(duration: nil, command: nil), credential: credential(intent: nil), approvals: nil)
        XCTAssertFalse(review.hasContent)
        XCTAssertNil(review.keykeeperSuggestsLine)
        XCTAssertEqual(review.rules.findings, [])
    }

    func test预选_规则建议优先_其次Agent要求_从不预选没提供的选项() {
        typealias Option = AuthorizationView.DurationOption
        let cron = credential(intent: .init(purpose: "nightly", frequency: .scheduled, background: true), expires: "2027-01-01")
        let fine = RequestReview.make(prompt: strict(duration: .always), credential: cron, approvals: nil)
        XCTAssertEqual(fine.rules.findings, [])
        XCTAssertEqual(Option.preselection(hasTerminalSession: true, canRemember: true, review: fine), .always, "规则没意见就顺着 Agent 的要求")

        let inflated = RequestReview.make(prompt: strict(duration: .always), credential: credential(intent: .init(purpose: "once", frequency: .once, background: false)), approvals: nil)
        XCTAssertEqual(Option.preselection(hasTerminalSession: true, canRemember: true, review: inflated), .once, "规则建议压过 Agent 要求")

        XCTAssertEqual(Option.preselection(hasTerminalSession: false, canRemember: true, review: RequestReview.make(prompt: strict(duration: .session), credential: nil, approvals: nil)), .oneHour, "没有终端会话就不预选「本会话」")
        XCTAssertEqual(Option.preselection(hasTerminalSession: true, canRemember: false, review: fine), .once, "认不出的调用方只有一次")
        XCTAssertEqual(Option.preselection(hasTerminalSession: true, canRemember: true, review: nil), .session)
    }

    func test服务弹窗的高亮按钮跟着建议走() {
        XCTAssertEqual(AuthorizationView.recommendedService(review: nil), .always)
        let asksHour = RequestReview.make(prompt: strict(duration: .oneHour), credential: nil, approvals: nil)
        XCTAssertEqual(AuthorizationView.recommendedService(review: asksHour), .oneHour)
        let inflated = RequestReview.make(prompt: strict(duration: .always), credential: credential(intent: .init(purpose: "once", frequency: .once, background: false)), approvals: nil)
        XCTAssertEqual(AuthorizationView.recommendedService(review: inflated), .once)
    }

    func test每条结论都有中文() {
        for finding in IntentFinding.allCases {
            let en = AppL10n.render(RequestReview.findingText(finding), language: "en")
            XCTAssertNotEqual(AppL10n.render(RequestReview.findingText(finding), language: "zh-Hans"), en, "\(finding)")
        }
    }

    func test保存弹窗_一次性用途却建议后台_点名并改成谨慎语气() {
        var request = ClipboardSaveRequest(credentialId: "vercel", fieldName: "token", create: true, security: .standard)
        request.intent = UsageIntent(purpose: "deploy once", frequency: .once, background: true)
        let model = TrustPromptModel.save(.init(request: request, callerName: "codex"))
        let labels = model.rows.map(\.label)
        XCTAssertTrue(labels.contains("Declared use") && labels.contains("KeyKeeper suggests"), "\(labels)")
        let suggests = model.rows.first { $0.label == "KeyKeeper suggests" }!
        XCTAssertTrue(suggests.value.contains("Ask every time") || suggests.value.contains("strict"), suggests.value)
        XCTAssertEqual(model.tone, .caution)

        var fine = ClipboardSaveRequest(credentialId: "backup", fieldName: "token", create: true, security: .standard, expires: "2027-01-01")
        fine.intent = UsageIntent(purpose: "nightly backup", expectedCaller: "cron", frequency: .scheduled, background: true)
        let ok = TrustPromptModel.save(.init(request: fine, callerName: "codex"))
        XCTAssertFalse(ok.rows.map(\.label).contains("KeyKeeper suggests"))
        XCTAssertTrue(ok.rows.first { $0.label == "Declared use" }!.note!.contains("cron"))

        let plain = TrustPromptModel.save(.init(request: ClipboardSaveRequest(credentialId: "x", fieldName: "f", create: true), callerName: "codex"))
        XCTAssertFalse(plain.rows.map(\.label).contains("Declared use"))
        XCTAssertFalse(plain.rows.map(\.label).contains("KeyKeeper suggests"), "什么都没建议就没有意见")
    }
}

private final class StubTransport: ReviewTransport, @unchecked Sendable {
    let reply: Data
    let lock = NSLock()
    var body: Data?
    var headers: [String: String] = [:]
    init(reply: Data) { self.reply = reply }
    var getURL: URL?
    func post(url: URL, headers: [String: String], body: Data) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        self.body = body; self.headers = headers
        return reply
    }
    func get(url: URL, headers: [String: String]) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        getURL = url; self.headers = headers
        return reply
    }
}

@MainActor
final class ReviewerServiceTests: XCTestCase {
    private func service() -> ReviewerService {
        let service = ReviewerService()
        service.defaults = UserDefaults(suiteName: "ReviewerServiceTests.\(UUID().uuidString)")!
        return service
    }

    private let input = IntentReviewInput(credentialId: "vercel", credentialLabel: "Vercel", fieldNames: ["token"], callerName: "codex",
                                          reason: "deploy", command: "vercel deploy", requestedDuration: .always)

    func test默认关闭_关着就不读key不联网() async {
        let service = service()
        var reads = 0
        service.retrieve = { _, _ in reads += 1; return "k" }
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.credentialId, ReviewerService.defaultCredentialId)
        let outcome = await service.review(input)
        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(reads, 0)
    }

    func test开了没存key_说清楚在哪存() async {
        let service = service()
        service.isEnabled = true
        service.credentialId = "  my-reviewer "
        let outcome = await service.review(input)
        guard case .unavailable(let why) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(why.contains("my-reviewer") && why.contains("api-key"), why)
    }

    func test开了有key_用app自己的读取_key只在头里_意见回来() async {
        let service = service()
        service.isEnabled = true
        let transport = StubTransport(reply: Data(#"{"content":[{"type":"text","text":"{\"necessity\":2,\"minimalScope\":false,\"suggestedDuration\":\"once\",\"comment\":\"one deploy\"}"}]}"#.utf8))
        service.transport = transport
        var asked: (String, String)?
        service.retrieve = { id, field in asked = (id, field); return "sk-ant-TEST" }
        let outcome = await service.review(input)
        XCTAssertEqual(outcome, .opinion(.init(necessity: 2, minimalScope: false, suggestedDuration: .once, comment: "one deploy")))
        XCTAssertEqual(asked?.0, "keykeeper-reviewer")
        XCTAssertEqual(asked?.1, "api-key")
        XCTAssertEqual(transport.headers["x-api-key"], "sk-ant-TEST")
        XCTAssertFalse(String(decoding: transport.body!, as: UTF8.self).contains("sk-ant-TEST"))
        let line = ReviewerService.line(for: .init(necessity: 2, minimalScope: false, suggestedDuration: .once, comment: "one deploy"))
        XCTAssertTrue(line.contains("2/5") && line.contains("Once") && line.hasSuffix("one deploy"), line)
    }

    /// yyt 2026-09-14：换个服务只要改 Base URL；接口按主机猜，模型从服务列出来的里面挑。
    func test默认Anthropic_换地址就按OpenAI兼容_列出的模型给人挑() async {
        let service = service()
        service.isEnabled = true
        service.retrieve = { _, _ in "sk-x" }
        XCTAssertEqual(service.endpoint?.api, .anthropic)
        XCTAssertEqual(service.endpoint?.model, "claude-sonnet-5")
        service.baseURLText = "https://api.deepseek.com/"
        XCTAssertEqual(service.endpoint?.api, .openAICompatible)
        service.apiOverride = .anthropic
        XCTAssertEqual(service.endpoint?.api, .anthropic, "人可以指定接口")
        service.apiOverride = nil
        let transport = StubTransport(reply: Data(#"{"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}"#.utf8))
        service.transport = transport
        guard case .success(let models) = await service.listModels() else { return XCTFail() }
        XCTAssertEqual(models, ["deepseek-chat", "deepseek-reasoner"])
        XCTAssertEqual(transport.getURL?.absoluteString, "https://api.deepseek.com/v1/models")
        XCTAssertEqual(transport.headers["authorization"], "Bearer sk-x")
        service.model = "deepseek-chat"
        XCTAssertEqual(service.endpoint?.completionURL.absoluteString, "https://api.deepseek.com/v1/chat/completions")
        service.baseURLText = "not a url"
        XCTAssertNil(service.endpoint)
        guard case .unavailable(let why) = await service.review(IntentReviewInput(credentialId: "c", credentialLabel: "L", callerName: "x")) else { return XCTFail() }
        XCTAssertTrue(why.lowercased().contains("url"), why)
    }

    func test超时就退回规则() async {
        let service = service()
        service.isEnabled = true
        service.retrieve = { _, _ in "k" }
        struct Slow: ReviewTransport {
            func post(url: URL, headers: [String: String], body: Data) async throws -> Data {
                try await Task.sleep(nanoseconds: 5_000_000_000); return Data()
            }
            func get(url: URL, headers: [String: String]) async throws -> Data { try await post(url: url, headers: headers, body: Data()) }
        }
        service.transport = Slow()
        do {
            _ = try await ReviewerService.withTimeout(0.05) { try await Slow().post(url: URL(string: "https://example.com")!, headers: [:], body: Data()) }
            XCTFail("should time out")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
