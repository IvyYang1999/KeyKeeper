import SwiftUI
import LocalAuthentication
import KeyKeeperCore

enum AuthorizationPrompt {
    case strict(AuthRequest)
    case service(IPCServer.PendingServiceRequest)

    var title: String {
        switch self {
        case .strict:
            return L("Authorization Request")
        case .service:
            return L("Service Authorization Request")
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
        }
    }

    private var rawCredentialLabel: String {
        switch self {
        case .strict(let request):
            return request.credentialLabel
        case .service(let request):
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
        }
    }

    var callerIdentity: CallerIdentity? {
        switch self {
        case .strict(let request):
            return request.callerIdentity
        case .service(let request):
            return request.callerIdentity
        }
    }
}

struct AuthorizationView: View {
    let prompt: AuthorizationPrompt
    /// Throwing lets the window show what went wrong and stay open, instead of
    /// closing as if the grant succeeded while the CLI receives a denial.
    let onAuthorize: (DurationChoice) throws -> Void
    let onDeny: () -> Void
    /// What the agent asks, what the rules think, and (if on) what the second model thinks.
    let review: RequestReview?

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

    init(prompt: AuthorizationPrompt,
         onAuthorize: @escaping (DurationChoice) throws -> Void,
         onDeny: @escaping () -> Void,
         review: RequestReview? = nil) {
        self.prompt = prompt
        self.onAuthorize = onAuthorize
        self.onDeny = onDeny
        self.review = review
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
        static func recommended(canRemember: Bool, canBindToRun: Bool, review: RequestReview?) -> DurationChoice {
            let offered = available(canRemember: canRemember, canBindToRun: canBindToRun)
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
    private var recommended: DurationChoice { DurationChoice.recommended(canRemember: callerAssurance.canRemember, canBindToRun: canBindToRun, review: review) }

    // yyt 2026-09-14: one thing per band, top to bottom — who wants what; what it says; what
    // KeyKeeper thinks; the three answers. Everything else is behind "Details".
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statedReasonSection
            adviceSection
            choiceButtons
            callerDetailsSection

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)   // the window's traffic lights sit in this band
        .padding(.bottom, 22)
        // Frosted like a system prompt, and the same surface as the save confirmations.
        // Capped at what the screen can show: expanded caller details used to make the window
        // taller than the display, and a clamped window shows only the middle of the glass —
        // which reads as four square corners.
        .authorizationPanel(width: 440, maxHeight: Self.availableHeight)
        .onAppear { startSettleTimer() }
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

    private var callerName: String {
        TrustPromptModel.sanitizedCaller(prompt.callerIdentity?.displayName ?? L("Unknown Caller"))
    }

    // MARK: - Bands

    /// Who wants what, and how sure KeyKeeper is about the who. The credential's ID is shown
    /// when it differs from the title, because any local process can retitle a credential
    /// without a prompt and the ID cannot be changed that way. 【独立审计 2026-09-14】
    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                callerKindIcon
                    .scaleEffect(0.55)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.background))
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("\(callerName) wants to use \(prompt.credentialLabel)"))
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: callerAssurance.symbolName)
                        .foregroundColor(callerAssurance.isReassuring ? .secondary : .orange)
                    Text(callerAssurance.label)
                    Text("·")
                    Text(prompt.fieldNames.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if prompt.credentialId != prompt.credentialLabel {
                        Text("·")
                        Text(prompt.credentialId)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var callerKindIcon: some View {
        if let caller = prompt.callerIdentity {
            switch caller.subject.kind {
            case .app:
                if let path = caller.executablePath,
                   let appPath = appBundlePath(from: path) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                        .resizable()
                        .frame(width: 40, height: 40)
                        .cornerRadius(8)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.blue)
                }
            case .script:
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
            case .executable:
                Image(systemName: "terminal.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.purple)
            }
        } else {
            Image(systemName: "questionmark.app")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
        }
    }

    /// What the caller wrote — the thing the person actually decides on, so it gets the room.
    /// Plain text, one label saying whose words these are and that nobody checked them; the
    /// command line under it in small type when the caller reported one.
    @ViewBuilder
    private var statedReasonSection: some View {
        if prompt.statedReason != nil || review?.input.command != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "quote.bubble")
                    Text(L("\(callerName) says"))
                    Text(L("not verified"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if let reason = prompt.statedReason {
                    Text(verbatim: reason.text)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let command = review?.input.command {
                    Text(verbatim: "$ " + command)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.card)
        }
    }

    /// KeyKeeper's own line (offline rules), and the reviewer's when the person turned it on.
    /// Nothing here when neither has anything to say.
    @ViewBuilder
    private var adviceSection: some View {
        if let review, review.keykeeperSuggestsLine != nil || review.agentAsksLine != nil || review.intentLine != nil || ReviewerService.shared.isEnabled {
            VStack(alignment: .leading, spacing: 6) {
                if let suggests = review.keykeeperSuggestsLine {
                    adviceRow("KeyKeeper", text: suggests, symbol: "checkmark.shield",
                              tone: review.rules.verdict == .inflated ? .orange : .secondary)
                } else if let asks = review.agentAsksLine {
                    adviceRow(L("Asks for"), text: asks, symbol: "hand.raised")
                }
                if let intent = review.intentLine {
                    adviceRow(L("Declared use"), text: intent, symbol: "text.book.closed")
                }
                if ReviewerService.shared.isEnabled {
                    switch reviewerOutcome {
                    case nil:
                        adviceRow(L("Reviewer"), text: L("asking…"), symbol: "person.crop.circle.badge.questionmark")
                    case .opinion(let opinion):
                        adviceRow(L("Reviewer"), text: ReviewerService.line(for: opinion), symbol: "person.crop.circle.badge.checkmark",
                                  tone: opinion.minimalScope && opinion.necessity >= 3 ? .secondary : .orange)
                    case .unavailable(let why):
                        adviceRow(L("Reviewer"), text: L("unavailable: \(why)"), symbol: "person.crop.circle.badge.exclamationmark")
                    case .disabled:
                        EmptyView()
                    }
                }
            }
            .task {
                guard ReviewerService.shared.isEnabled, reviewerOutcome == nil else { return }
                reviewerOutcome = await ReviewerService.shared.review(review.input)
            }
        }
    }

    private func adviceRow(_ label: String, text: String, symbol: String, tone: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.caption).foregroundColor(tone)
            Text(label).font(.caption.weight(.semibold)).foregroundColor(tone)
            Text(verbatim: text)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// Deny on the left; the answers on the right, the recommended one prominent. One line
    /// under them says what "don't ask again" would cover for this caller.
    private var choiceButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: DS.Spacing.sm) {
                Button(role: .destructive) { onDeny() } label: { Text(L("Deny")) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape)
                Spacer()
                ForEach(choices, id: \.self) { choice in
                    choiceButton(choice)
                }
            }
            .controlSize(.large)
            Text(choiceScopeLine)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        }
        .disabled(isAuthenticating || !canApprove)
        if prominent { button.buttonStyle(.borderedProminent) } else { button }
    }

    /// Everything that used to fill the window: the facts, the wording about what the tier
    /// means, the diagnostics. One click away.
    @ViewBuilder
    private var callerDetailsSection: some View {
        DisclosureGroup(isExpanded: $showCallerDetails) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                detailRow(L("Credential"), value: prompt.credentialId == prompt.credentialLabel ? prompt.credentialLabel : "\(prompt.credentialLabel) · \(prompt.credentialId)")
                detailRow(L("Keys"), value: prompt.fieldNames.joined(separator: ", "))
                // "From" only when there is a terminal session to name; "no terminal session" is noise.
                if prompt.hasTerminalSession, let sessionLabel = prompt.sessionLabel {
                    detailRow(L("From"), value: CallerStatedReason.printableLine(AppL10n.text(sessionLabel), limit: 80))
                }
                Divider()
                // The wording that used to fill the window: still here, one click away.
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
