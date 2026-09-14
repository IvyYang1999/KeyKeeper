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
        XCTAssertTrue(review.keykeeperSuggestsLine!.contains("Just this once"), review.keykeeperSuggestsLine!)
        XCTAssertEqual(review.agentAsksLine, "Don't ask again")
        XCTAssertTrue(review.intentLine!.hasPrefix("one deploy ("), review.intentLine!)
    }

    func test什么都没要没声明_没有内容() {
        let review = RequestReview.make(prompt: strict(duration: nil, command: nil), credential: credential(intent: nil), approvals: nil)
        XCTAssertFalse(review.hasContent)
        XCTAssertNil(review.keykeeperSuggestsLine)
        XCTAssertEqual(review.rules.findings, [])
    }

    func test推荐档_规则建议优先_其次Agent要求_从不推荐没提供的() {
        typealias Choice = AuthorizationView.DurationChoice
        let cron = credential(intent: .init(purpose: "nightly", frequency: .scheduled, background: true), expires: "2027-01-01")
        let fine = RequestReview.make(prompt: strict(duration: .always), credential: cron, approvals: nil)
        XCTAssertEqual(fine.rules.findings, [])
        XCTAssertEqual(Choice.recommended(canRemember: true, canBindToRun: true, review: fine), .always, "规则没意见就顺着 Agent 的要求")

        let inflated = RequestReview.make(prompt: strict(duration: .always), credential: credential(intent: .init(purpose: "once", frequency: .once, background: false)), approvals: nil)
        XCTAssertEqual(Choice.recommended(canRemember: true, canBindToRun: true, review: inflated), .once, "规则建议压过 Agent 要求")

        let asksHour = RequestReview.make(prompt: strict(duration: .oneHour), credential: nil, approvals: nil)
        XCTAssertEqual(Choice.recommended(canRemember: true, canBindToRun: true, review: asksHour), .thisRun, "旧的「1 小时」折成这次运行期间")
        XCTAssertEqual(Choice.recommended(canRemember: true, canBindToRun: false, review: asksHour), .once, "绑不到运行就不推荐中间档")
        XCTAssertEqual(Choice.recommended(canRemember: false, canBindToRun: true, review: fine), .once, "认不出的调用方只有一次")
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
        ReviewerService(store: .inMemory())
    }

    /// 【今天自己埋的 critical】设置若在 UserDefaults 里，任何进程一条 `defaults write` 就能让 App 把一条真凭据
    /// 的值当审查员的 key 发到攻击者的地址。现在设置只认 App 独占的钥匙串文档；UserDefaults 里写什么都没用。
    func test设置只认钥匙串文档_UserDefaults里的东西不算数() async {
        let defaults = UserDefaults(suiteName: "ReviewerServiceTests.\(UUID().uuidString)")!
        defaults.set(true, forKey: "reviewerEnabled")
        defaults.set("https://evil.example", forKey: "reviewerBaseURL")
        let service = service()
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.baseURLText, ReviewerEndpoint.defaultBaseURL)
        let outcome = await service.review(input)
        XCTAssertEqual(outcome, .disabled)
        // And what the person sets survives a new service over the same store.
        service.isEnabled = true; service.baseURLText = "https://api.deepseek.com"; service.model = "deepseek-chat"
        let again = ReviewerService(store: service.store)
        XCTAssertTrue(again.isEnabled)
        XCTAssertEqual(again.endpoint?.completionURL.absoluteString, "https://api.deepseek.com/v1/chat/completions")
    }

    private let input = IntentReviewInput(credentialId: "vercel", credentialLabel: "Vercel", fieldNames: ["token"], callerName: "codex",
                                          reason: "deploy", command: "vercel deploy", requestedDuration: .always)

    func test默认关闭_关着就不联网() async {
        let service = service()
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.hasKey)
        let outcome = await service.review(input)
        XCTAssertEqual(outcome, .disabled)
    }

    func test开了没填key_说清楚() async {
        let service = service()
        service.isEnabled = true
        let outcome = await service.review(input)
        guard case .unavailable(let why) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(why.contains("key"), why)
    }

    /// 【独立审计 2026-09-14】key 不再是一条凭据（凭据名可被任何进程免弹窗改），而是人填进设置、
    /// 存在 App 独占钥匙串文档里的一个值。
    func test开了有key_key只在头里_意见回来() async {
        let service = service()
        service.isEnabled = true
        let transport = StubTransport(reply: Data(#"{"content":[{"type":"text","text":"{\"necessity\":2,\"minimalScope\":false,\"suggestedDuration\":\"once\",\"comment\":\"one deploy\"}"}]}"#.utf8))
        service.transport = transport
        service.apiKey = " sk-ant-TEST\n"
        XCTAssertTrue(service.hasKey)
        XCTAssertEqual(try service.store.reviewerSettings()?.apiKey, "sk-ant-TEST", "存在钥匙串文档里")
        let outcome = await service.review(input)
        XCTAssertEqual(outcome, .opinion(.init(necessity: 2, minimalScope: false, suggestedDuration: .once, comment: "one deploy")))
        XCTAssertEqual(transport.headers["x-api-key"], "sk-ant-TEST")
        XCTAssertFalse(String(decoding: transport.body!, as: UTF8.self).contains("sk-ant-TEST"))
        let line = ReviewerService.line(for: .init(necessity: 2, minimalScope: false, suggestedDuration: .once, comment: "one deploy"))
        XCTAssertTrue(line.contains("2/5") && line.contains("Just this once") && line.hasSuffix("one deploy"), line)
    }

    /// yyt 2026-09-14：换个服务只要改 Base URL；接口按主机猜，模型从服务列出来的里面挑。
    func test默认Anthropic_换地址就按OpenAI兼容_列出的模型给人挑() async {
        let service = service()
        service.isEnabled = true
        service.apiKey = "sk-x"
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
        service.apiKey = "k"
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
