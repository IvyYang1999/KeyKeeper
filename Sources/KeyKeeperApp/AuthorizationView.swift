import SwiftUI
import LocalAuthentication
import KeyKeeperCore

/// An approval raised from the access log rather than from a live request: "this caller asked
/// and nobody answered in time — approve it now, so the next call goes through". yyt 2026-09-15.
struct StandingApprovalRequest {
    let credentialId: String
    let credentialLabel: String
    let fieldNames: [String]
    let callerIdentity: CallerIdentity
    let reason: String?
    let command: String?

    /// Nil when the subject could never hold an approval (unverified).
    init?(group: AccessLogGroup, credentialLabel: String, fieldNames: [String]) {
        guard GrantIssuancePolicy.mayRemember(subjectFingerprint: group.fingerprint) else { return nil }
        let kind: CallerSubject.Kind = group.fingerprint.contains("app:") ? .app : group.fingerprint.contains("script:") ? .script : .executable
        self.credentialId = group.credentialId
        self.credentialLabel = credentialLabel
        self.fieldNames = fieldNames
        self.callerIdentity = CallerIdentity(peerPID: 0, subject: CallerSubject(kind: kind, fingerprint: group.fingerprint,
                                                                                 displayName: group.who, detail: ""))
        self.reason = group.reason
        self.command = group.command
    }
}

/// How the access log reaches the authorization window, which the app delegate owns.
@MainActor
final class StandingApprovalRequester {
    static let shared = StandingApprovalRequester()
    var handler: ((StandingApprovalRequest) -> Void)?
}

enum AuthorizationPrompt {
    case strict(AuthRequest)
    case service(IPCServer.PendingServiceRequest)
    case standing(StandingApprovalRequest)

    var title: String {
        switch self {
        case .strict:
            return L("Authorization Request")
        case .service:
            return L("Service Authorization Request")
        case .standing:
            return L("Approve for next time")
        }
    }

    /// The prompt's headline. KeyKeeper looks this up locally rather than taking the caller's
    /// word for it, but the label itself is free text that any local process can rewrite over
    /// the socket without a prompt — renaming is deliberately unobtrusive. So it gets the same
    /// treatment as the caller's stated reason: one printable line, capped, before it is drawn
    /// in bold at the top of an authorization window. Falls back to the credential's ID when
    /// nothing printable is left.
    var credentialLabel: String {
        let line = CallerStatedReason.printableLine(rawCredentialLabel, limit: 120)
        return line.isEmpty ? credentialId : line
    }

    var credentialId: String {
        switch self {
        case .strict(let request):
            return request.credentialId
        case .service(let request):
            return request.credentialId
        case .standing(let request):
            return request.credentialId
        }
    }

    private var rawCredentialLabel: String {
        switch self {
        case .strict(let request):
            return request.credentialLabel
        case .service(let request):
            return request.credentialLabel
        case .standing(let request):
            return request.credentialLabel
        }
    }

    /// The caller's own sentence about why it wants this. Sanitized again here: the view
    /// never renders a string straight off the socket.
    var statedReason: CallerStatedReason? {
        switch self {
        case .strict(let request):
            return CallerStatedReason.sanitize(request.statedReason?.text)
        case .service(let request):
            return CallerStatedReason.sanitize(request.request.statedReason?.text)
        case .standing(let request):
            return CallerStatedReason.sanitize(request.reason)
        }
    }

    var isStrict: Bool {
        if case .strict = self { return true }
        return false
    }

    var fieldNames: [String] {
        switch self {
        case .strict(let request):
            return request.fieldNames
        case .service(let request):
            return request.fieldNames
        case .standing(let request):
            return request.fieldNames
        }
    }

    /// The terminal the caller says it is in. Caller-supplied — the only row in the verified-facts
    /// card that KeyKeeper does not establish itself — so it is folded to one printable line
    /// before it is drawn, like every other piece of somebody else's text in this window.
    var sessionLabel: String? {
        guard case .strict(let request) = self else { return nil }
        return request.sessionLabel
    }

    /// Terminal session the caller belongs to, when it has one. Cron, IDE and SDK
    /// callers usually do not, and a "this session" grant cannot be issued for them.
    var hasTerminalSession: Bool {
        guard case .strict(let request) = self,
              let sessionId = request.sessionId else { return false }
        return !sessionId.isEmpty
    }

    var pid: Int32 {
        switch self {
        case .strict(let request):
            return request.callerIdentity?.peerPID ?? request.pid
        case .service(let request):
            return request.callerIdentity.peerPID
        case .standing:
            return 0
        }
    }

    var callerIdentity: CallerIdentity? {
        switch self {
        case .strict(let request):
            return request.callerIdentity
        case .service(let request):
            return request.callerIdentity
        case .standing(let request):
            return request.callerIdentity
        }
    }

    /// The caller said nothing about why. Shown plainly; the recommended answer drops to once.
    var reasonMissing: Bool { statedReason == nil }
}

struct AuthorizationView: View {
    let prompt: AuthorizationPrompt
    /// Throwing lets the window show what went wrong and stay open, instead of
    /// closing as if the grant succeeded while the CLI receives a denial.
    let onAuthorize: (DurationChoice) throws -> Void
    let onDeny: () -> Void
    /// What the agent asks, what the rules think, and (if on) what the second model thinks.
    let review: RequestReview?
    private let reviewerService: ReviewerService

    @State private var reviewerOutcome: ReviewerService.Outcome?
    @State private var isAuthenticating = false
    @State private var errorMessage: String?
    @State private var showCallerDetails = false
    /// A click already travelling toward the screen must not land on a window that just appeared.
    @State private var canApprove = false
    private let shownAt = Date()
    private let authenticationMethod: AuthenticationMethod

    /// What to do after a LocalAuthentication round.
    ///
    /// 【曾经的 bug】yyt 2026-09-13：在 Touch ID 面板点「使用密码」后窗口直接消失。旧实现把
    /// `LAError.userFallback` 当成验证通过就放行了——等于谁都能点两下绕开 Touch ID 拿到值。
    /// 现在「改用密码」只会换成密码策略再验一次，验过才放行；验不了就报错，绝不放行。
    enum AuthenticationOutcome: Equatable {
        case authorize
        case askForDevicePassword
        case cancelled
        case failed(String)

        static func decide(success: Bool,
                           code: LAError.Code?,
                           devicePasswordAvailable: Bool,
                           isPasswordRound: Bool = false,
                           message: String? = nil) -> AuthenticationOutcome {
            if success { return .authorize }
            switch code {
            case .userCancel, .appCancel, .systemCancel:
                return .cancelled
            case .userFallback, .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
                guard devicePasswordAvailable, !isPasswordRound else {
                    return .failed(L("This Mac can't verify it is you right now. Unlock it with your Mac password or set up Touch ID, then try again."))
                }
                return .askForDevicePassword
            default:
                return .failed(message ?? L("Authentication failed"))
            }
        }
    }

    /// One round of verification, and what the system will actually show for it.
    ///
    /// 【曾经的 bug】yyt 2026-09-13 下午：点「使用密码」之后又弹出一次 Touch ID，要再点一次
    /// 才出密码输入框。因为第二轮用的是 `.deviceOwnerAuthentication`，而那个策略本来就先试
    /// 生物识别。密码轮必须走「只认密码」的 SecAccessControl，绕开生物识别这条路。
    enum AuthenticationRound: Equatable {
        case biometrics
        case devicePasswordOnly

        /// Nil for the password round on purpose: any LAPolicy here can put Touch ID back on screen.
        var policy: LAPolicy? {
            switch self {
            case .biometrics: return .deviceOwnerAuthenticationWithBiometrics
            case .devicePasswordOnly: return nil
            }
        }

        var accessControlFlags: SecAccessControlCreateFlags? {
            switch self {
            case .biometrics: return nil
            case .devicePasswordOnly: return .devicePasscode
            }
        }

        var isPasswordRound: Bool { self == .devicePasswordOnly }

        func accessControl() -> SecAccessControl? {
            guard let accessControlFlags else { return nil }
            return SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, accessControlFlags, nil)
        }
    }

    /// How the "Authorize" click is confirmed. The button icon must match what will
    /// actually happen; a Touch ID glyph on a machine without Touch ID promised a
    /// check that never ran.
    enum AuthenticationMethod: Equatable {
        case biometrics
        case devicePassword
        case none

        static func choose(biometricsAvailable: Bool, devicePasswordAvailable: Bool) -> AuthenticationMethod {
            if biometricsAvailable { return .biometrics }
            if devicePasswordAvailable { return .devicePassword }
            return .none
        }

        var symbolName: String {
            switch self {
            case .biometrics: return "touchid"
            case .devicePassword: return "lock.fill"
            case .none: return "checkmark.circle"
            }
        }

        var policy: LAPolicy? {
            switch self {
            case .biometrics: return .deviceOwnerAuthenticationWithBiometrics
            case .devicePassword: return .deviceOwnerAuthentication
            case .none: return nil
            }
        }

        static func detect() -> AuthenticationMethod {
            let context = LAContext()
            var error: NSError?
            let biometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
                && error == nil
            error = nil
            let password = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
                && error == nil
            return choose(biometricsAvailable: biometrics, devicePasswordAvailable: password)
        }
    }

    @MainActor init(prompt: AuthorizationPrompt,
         onAuthorize: @escaping (DurationChoice) throws -> Void,
         onDeny: @escaping () -> Void,
         review: RequestReview? = nil,
         reviewerService: ReviewerService? = nil,
         initiallyExpanded: Bool = false) {
        self.prompt = prompt
        self.onAuthorize = onAuthorize
        self.onDeny = onDeny
        self.review = review
        self.reviewerService = reviewerService ?? .shared
        self._showCallerDetails = State(initialValue: initiallyExpanded)
        self.authenticationMethod = AuthenticationMethod.detect()
    }

    /// The three answers. yyt 2026-09-14: "once / 1 hour / always" were all about time, and
    /// "always" was the only way not to be asked again for the same agent doing the same job —
    /// at the price of forever. The middle answer is now the job: while that process runs.
    enum DurationChoice: String, CaseIterable {
        case once = "Just this once"
        case thisRun = "While it runs"
        case always = "Don't ask again"

        init(requested: RequestedDuration) {
            switch requested.folded {
            case .once: self = .once
            case .always: self = .always
            default: self = .thisRun
            }
        }

        /// Nothing but "once" for a caller that cannot be identified; no "while it runs" when
        /// there is neither a terminal session nor a located process to tie it to.
        static func available(canRemember: Bool, canBindToRun: Bool) -> [DurationChoice] {
            guard canRemember else { return [.once] }
            return canBindToRun ? [.once, .thisRun, .always] : [.once, .always]
        }

        /// The one drawn prominent: the rules' suggestion when they made one, the agent's own
        /// wish when they did not, otherwise "while it runs" — never an answer not on offer.
        static func recommended(canRemember: Bool, canBindToRun: Bool, review: RequestReview?, reasonMissing: Bool = false) -> DurationChoice {
            let offered = available(canRemember: canRemember, canBindToRun: canBindToRun)
            if reasonMissing { return .once }
            let wanted = review?.rules.suggestedDuration ?? review?.input.requestedDuration
            if let wanted, offered.contains(DurationChoice(requested: wanted)) { return DurationChoice(requested: wanted) }
            return offered.contains(.thisRun) ? .thisRun : .once
        }
    }

    /// The tier that decides what "Allow" can honestly promise.
    private var callerAssurance: CallerAssurance {
        prompt.callerIdentity.map { CallerAssurance.of($0.subject) } ?? .unverified
    }

    private var canBindToRun: Bool { prompt.hasTerminalSession || prompt.callerIdentity?.subjectPID != nil }
    private var choices: [DurationChoice] { DurationChoice.available(canRemember: callerAssurance.canRemember, canBindToRun: canBindToRun) }
    private var recommended: DurationChoice { DurationChoice.recommended(canRemember: callerAssurance.canRemember, canBindToRun: canBindToRun, review: review, reasonMissing: prompt.reasonMissing) }

    // yyt 2026-09-27: "我每次基本上啥都不看的，直接就摁了「以后都不问」". So the window is built
    // for the one glance it actually gets: whose icon, which key, its sentence, three buttons.
    // KeyKeeper speaks only when something is off — one orange line — and everything else
    // is behind "Details". Compare 1Password's prompt: an icon pair, one sentence, buttons.
    var body: some View {
        VStack(spacing: 0) {
            header
            reasonSection
                .padding(.top, 14)
            flagSection
                .padding(.top, 10)
            choiceButtons
                .padding(.top, 18)
            callerDetailsSection
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)   // the window's traffic lights sit in this band
        .padding(.bottom, 20)
        // yyt 2026-09-27: "这个预览图的黄蓝渐变也很好看" — the brand's pale yellow and blue, only in
        // the top band and only here, behind the icon pair. The rest of the app stays uncoloured.
        .background(brandTint)
        .authorizationPanel(width: 420, maxHeight: Self.availableHeight)
        .onAppear { startSettleTimer() }
        .task {
            guard let review, reviewerService.isEnabled, reviewerOutcome == nil else { return }
            reviewerOutcome = await reviewerService.review(review.input)
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var brandTint: some View {
        let strength = colorScheme == .dark ? 0.45 : 1.0
        return ZStack {
            RadialGradient(colors: [Color(red: 1, green: 0.94, blue: 0.76).opacity(0.9 * strength), .clear],
                           center: UnitPoint(x: 0.22, y: 0), startRadius: 0, endRadius: 260)
            RadialGradient(colors: [Color(red: 0.83, green: 0.89, blue: 1).opacity(0.9 * strength), .clear],
                           center: UnitPoint(x: 0.85, y: 0.05), startRadius: 0, endRadius: 260)
        }
        .allowsHitTesting(false)
    }

    static var availableHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(360, visible - 80)
    }

    private func startSettleTimer() {
        guard !canApprove else { return }
        let remaining = ApprovalReadiness.settleDelay - Date().timeIntervalSince(shownAt)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, remaining)) { canApprove = true }
    }

    /// "Codex", not "com.openai.codex.cli". The identifier is in Details.
    private var callerName: String {
        let raw = prompt.callerIdentity?.displayName ?? L("Unknown Caller")
        if let id = prompt.callerIdentity?.bundleIdentifier, let name = CallerAppIcon.friendlyName(for: id) { return name }
        if let name = CallerAppIcon.friendlyName(for: raw) { return name }
        // An app KeyKeeper has no name for: what the Finder calls it ("Dark Console"), not its bundle id.
        if let path = prompt.callerIdentity?.executablePath, let app = appBundlePath(from: path) {
            let shown = FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: "")
            let line = CallerStatedReason.printableLine(shown, limit: 60)
            if !line.isEmpty { return line }
        }
        return TrustPromptModel.sanitizedCaller(raw)
    }

    // MARK: - Bands

    /// The caller's own icon, large, with KeyKeeper as the badge; one bold line saying who wants
    /// which key. The credential's ID appears only when it differs from the title, because any
    /// local process can retitle a credential without a prompt. 【独立审计 2026-09-14】
    private var header: some View {
        VStack(spacing: 14) {
            // yyt 2026-09-27: like 1Password — the caller on the left, KeyKeeper on the right,
            // a link between them; not one icon badged with the other.
            HStack(spacing: 0) {
                callerKindIcon
                    .frame(width: 56, height: 56)
                HStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 34, height: 2)
                    Image(systemName: callerAssurance.canRemember ? "checkmark.circle.fill" : "questionmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(callerAssurance.canRemember ? .green : .orange)
                        .background(Circle().fill(.background).padding(1))
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 34, height: 2)
                }
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
            }
            VStack(spacing: 3) {
                Text(L("\(callerName) wants to use \(prompt.credentialLabel)"))
                    .font(.system(size: 17, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if prompt.credentialId != prompt.credentialLabel {
                    Text(prompt.credentialId)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var callerKindIcon: some View {
        if let caller = prompt.callerIdentity {
            // The real icon when the Mac has it: a command-line agent (Claude Code, Codex CLI)
            // shows the desktop app it belongs to. yyt 2026-09-15: "一目了然".
            if let image = CallerAppIcon.image(for: caller.bundleIdentifier ?? caller.subject.displayName) {
                Image(nsImage: image).resizable().cornerRadius(11)
            } else {
                switch caller.subject.kind {
                case .app:
                    if let path = caller.executablePath, let appPath = appBundlePath(from: path) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appPath)).resizable().cornerRadius(11)
                    } else {
                        genericIcon("app.fill", .blue)
                    }
                case .script: genericIcon("doc.text.fill", .orange)
                case .executable: genericIcon("terminal.fill", .purple)
                }
            }
        } else {
            genericIcon("questionmark.app", .secondary)
        }
    }

    private func genericIcon(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30))
            .foregroundColor(color)
            .frame(width: 52, height: 52)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.secondary.opacity(0.12)))
    }

    /// The caller's sentence in a card labelled with its name: "Codex says". That is the whole
    /// decision most of the time, so it gets the room and a surface of its own.
    @ViewBuilder
    private var reasonSection: some View {
        if let reason = prompt.statedReason {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("\(callerName) says"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(verbatim: reason.text)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.raised, radius: DS.Radius.md)
        }
    }

    /// KeyKeeper speaks only when something is off, one line, orange: no reason given, an
    /// unverifiable caller, a request the rules call inflated, or a reviewer that objects.
    /// A request that checks out gets no line at all.
    @ViewBuilder
    private var flagSection: some View {
        let flags = warningLines
        if !flags.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(flags, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                        Text(verbatim: line).font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(.orange)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var warningLines: [String] {
        var lines: [String] = []
        if prompt.reasonMissing { lines.append(L("\(callerName) gave no reason for this request.")) }
        // Orange only for a caller that cannot be told apart from anyone else; "unsigned but
        // identified by its file" is a fact for Details, not a warning.
        if !callerAssurance.canRemember { lines.append(callerAssurance.label) }
        if let review, review.rules.verdict == .inflated, let line = review.keykeeperSuggestsLine { lines.append(line) }
        if case .opinion(let opinion) = reviewerOutcome, !(opinion.minimalScope && opinion.necessity >= 3) {
            lines.append(ReviewerService.line(for: opinion))
        }
        return lines
    }

    /// One row (yyt 2026-09-27: four stacked buttons were "很难受"): Deny on the left; on the
    /// right the recommended answer, blue and last, and before it the other answers folded into
    /// one split button — its label is the next most likely answer, the rest are in its menu.
    private var choiceButtons: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button { onDeny() } label: { Text(L("Deny")).fixedSize().foregroundStyle(.red) }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)
            Spacer()
            if let first = otherChoices.first {
                if otherChoices.count == 1 {
                    choiceButton(first)
                } else {
                    Menu {
                        ForEach(otherChoices.dropFirst(), id: \.self) { choice in
                            Button(AppL10n.text(choice.rawValue)) { authenticate { try onAuthorize(choice) } }
                        }
                    } label: {
                        Text(AppL10n.text(first.rawValue)).fixedSize()
                    } primaryAction: {
                        authenticate { try onAuthorize(first) }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .disabled(isAuthenticating || !canApprove)
                    .help(choiceScopeLine)
                }
            }
            choiceButton(recommended)
        }
        .controlSize(.large)
    }

    /// The answers that are not the recommended one, most permanent first: "don't ask again"
    /// is what the person reaches for when they disagree with a cautious recommendation.
    private var otherChoices: [DurationChoice] {
        [DurationChoice.always, .thisRun, .once].filter { $0 != recommended && choices.contains($0) }
    }

    private var choiceScopeLine: String {
        guard callerAssurance.canRemember else { return callerAssurance.scopeSummaryLine(caller: callerName) }
        var parts: [String] = []
        if choices.contains(.thisRun) {
            parts.append(prompt.hasTerminalSession
                         ? L("\u{201C}While it runs\u{201D} ends with this terminal session.")
                         : L("\u{201C}While it runs\u{201D} ends when \(callerName) quits."))
        }
        parts.append(L("\u{201C}Don't ask again\u{201D} lasts until you revoke it."))
        parts.append(callerAssurance.scopeSummaryLine(caller: callerName))
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private func choiceButton(_ choice: DurationChoice) -> some View {
        let prominent = choice == recommended
        let button = Button {
            authenticate { try onAuthorize(choice) }
        } label: {
            HStack(spacing: 4) {
                if prominent {
                    if isAuthenticating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: authenticationMethod.symbolName)
                    }
                }
                Text(AppL10n.text(choice.rawValue))
            }
            .fixedSize()
        }
        .disabled(isAuthenticating || !canApprove)
        .help(choice == .always ? choiceScopeLine : "")
        if prominent { button.buttonStyle(.borderedProminent) } else { button }
    }

    /// Everything that used to fill the window: what the buttons cover, what the caller asked
    /// for and declared, its command line, the reviewer, the identity facts. One click away.
    @ViewBuilder
    private var callerDetailsSection: some View {
        DisclosureGroup(isExpanded: $showCallerDetails) {
            // SwiftUI may build disclosure content while it is collapsed. Keep hidden
            // diagnostics (including the reviewer settings in Keychain) out of that pass.
            if showCallerDetails {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text(choiceScopeLine)
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    detailRow(L("Credential"), value: prompt.credentialId == prompt.credentialLabel ? prompt.credentialLabel : "\(prompt.credentialLabel) · \(prompt.credentialId)")
                    detailRow(L("Keys"), value: prompt.fieldNames.joined(separator: ", "))
                    if let review {
                        if let asks = review.agentAsksLine { detailRow(L("Asks for"), value: asks) }
                        if let intent = review.intentLine { detailRow(L("Declared use"), value: intent) }
                        if let command = review.input.command { detailRow(L("Command"), value: "$ " + command) }
                        if let suggests = review.keykeeperSuggestsLine, review.rules.verdict != .inflated { detailRow("KeyKeeper", value: suggests) }
                    }
                    // No review input means there can be no reviewer result.
                    if review != nil && reviewerService.isEnabled {
                        switch reviewerOutcome {
                        case nil: detailRow(L("Reviewer"), value: L("asking…"))
                        case .opinion(let opinion): detailRow(L("Reviewer"), value: ReviewerService.line(for: opinion))
                        case .unavailable(let why): detailRow(L("Reviewer"), value: L("unavailable: \(why)"))
                        case .disabled: EmptyView()
                        }
                    }
                    // "From" only when there is a terminal session to name; "no terminal session" is noise.
                    if prompt.hasTerminalSession, let sessionLabel = prompt.sessionLabel {
                        detailRow(L("From"), value: CallerStatedReason.printableLine(AppL10n.text(sessionLabel), limit: 80))
                    }
                    Divider()
                    detailRow(L("Identity"), value: callerAssurance.label)
                    Text(callerAssurance.explanation)
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(callerAssurance.scopeLine(caller: callerName, wholeCredential: prompt.isStrict))
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if prompt.isStrict, !prompt.hasTerminalSession, !canBindToRun {
                        Text(L("This caller has no terminal session (cron, IDE or SDK), so a per-session grant isn't available."))
                            .font(.caption2).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let caller = prompt.callerIdentity {
                        Divider()
                        if let path = caller.executablePath {
                            detailRow(L("Path"), value: path)
                        }
                        if let bundle = caller.bundleIdentifier {
                            detailRow(L("Bundle"), value: bundle)
                        }
                        if let team = caller.teamIdentifier {
                            detailRow(L("Team ID"), value: team)
                        }
                        if let signing = caller.signingIdentifier {
                            detailRow(L("Signing"), value: signing)
                        }
                        detailRow(L("Subject"), value: shortFingerprint(caller.subjectFingerprint))
                        detailRow("PID", value: "\(caller.peerPID)")

                        if caller.parentChain.count > 1 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Process Chain"))
                                    .font(.caption2)
                                    .foregroundColor(.secondary.opacity(0.8))
                                Text(CallerStatedReason.printableLine(processChainText(caller.parentChain), limit: 400))
                                    .font(.caption.monospaced())
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .padding(.top, DS.Spacing.xs)
            }
        } label: {
            Label(L("Details"), systemImage: "info.circle")
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    /// Every one of these values comes from the caller's own process — paths, bundle ids, the
    /// process chain. They were the last strings in this window drawn straight through.
    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.8))
            Spacer(minLength: 12)
            Text(CallerStatedReason.printableLine(value, limit: 200))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    /// Runs the grant callback and keeps the window open with the reason when it fails.
    private func finishAuthorization(_ completion: () throws -> Void) {
        do {
            try completion()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func authenticate(_ completion: @escaping () throws -> Void) {
        guard let policy = authenticationMethod.policy else {
            // Neither biometrics nor a device password can be evaluated (for example an
            // unsigned debug build): the click itself is the confirmation.
            finishAuthorization(completion)
            return
        }
        runAuthentication(round: policy == .deviceOwnerAuthentication ? .devicePasswordOnly : .biometrics,
                          completion: completion)
    }

    /// One LocalAuthentication round. Choosing "Use Password…" runs a second round with the
    /// device-password policy; nothing is released until a round actually succeeds.
    private func runAuthentication(round: AuthenticationRound,
                                   completion: @escaping () throws -> Void) {
        isAuthenticating = true
        errorMessage = nil

        let context = LAContext()
        let reason = L("Authorize access to \"\(prompt.credentialLabel)\"")
        let handle: (Bool, Error?) -> Void = { success, authError in
            DispatchQueue.main.async {
                let outcome = AuthenticationOutcome.decide(
                    success: success,
                    code: (authError as? LAError)?.code,
                    devicePasswordAvailable: LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil),
                    isPasswordRound: round.isPasswordRound,
                    message: authError?.localizedDescription
                )
                switch outcome {
                case .authorize:
                    isAuthenticating = false
                    finishAuthorization(completion)
                case .askForDevicePassword:
                    // The system password sheet is the next step; keep the window busy.
                    runAuthentication(round: .devicePasswordOnly, completion: completion)
                case .cancelled:
                    isAuthenticating = false
                    errorMessage = L("Cancelled")
                case .failed(let message):
                    isAuthenticating = false
                    errorMessage = message
                }
            }
        }
        if let policy = round.policy {
            context.evaluatePolicy(policy, localizedReason: reason, reply: handle)
        } else if let accessControl = round.accessControl() {
            // Password only: no policy, so the system cannot decide to try Touch ID first.
            context.evaluateAccessControl(accessControl, operation: .useKeyDecrypt, localizedReason: reason, reply: handle)
        } else {
            handle(false, nil)
        }
    }

    private func appBundlePath(from executablePath: String) -> String? {
        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard let appIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[0...appIndex]))
    }

    private func processChainText(_ chain: [CallerProcess]) -> String {
        chain.reversed().map(\.displayName).joined(separator: " \u{2192} ")
    }

    private func shortFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.count > 32 else { return fingerprint }
        return "\(fingerprint.prefix(18))...\(fingerprint.suffix(10))"
    }
}
