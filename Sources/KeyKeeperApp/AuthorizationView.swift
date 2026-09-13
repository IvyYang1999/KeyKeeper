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

    var fieldNames: [String] {
        switch self {
        case .strict(let request):
            return request.fieldNames
        case .service(let request):
            return request.fieldNames
        }
    }

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
    let onAuthorizeGrant: ((GrantDuration) throws -> Void)?
    let onAuthorizeService: ((ServiceGrantDuration) throws -> Void)?
    let onDeny: () -> Void

    @State private var selectedDuration: DurationOption
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
         onAuthorizeGrant: ((GrantDuration) throws -> Void)?,
         onAuthorizeService: ((ServiceGrantDuration) throws -> Void)?,
         onDeny: @escaping () -> Void) {
        self.prompt = prompt
        self.onAuthorizeGrant = onAuthorizeGrant
        self.onAuthorizeService = onAuthorizeService
        self.onDeny = onDeny
        self.authenticationMethod = AuthenticationMethod.detect()
        _selectedDuration = State(initialValue: DurationOption.defaultSelection(
            hasTerminalSession: prompt.hasTerminalSession
        ))
    }

    enum DurationOption: String, CaseIterable {
        case once = "Just this once"
        case session = "This terminal session"
        case oneHour = "1 hour"
        case always = "Always"

        var grantDuration: GrantDuration {
            switch self {
            case .once: return .once
            case .session: return .session("")  // session ID filled by caller
            case .oneHour: return .timed(Date().addingTimeInterval(3600))
            case .always: return .always
            }
        }

        /// "This terminal session" is only offered when the caller actually has one.
        static func available(hasTerminalSession: Bool) -> [DurationOption] {
            allCases.filter { $0 != .session || hasTerminalSession }
        }

        static func defaultSelection(hasTerminalSession: Bool) -> DurationOption {
            hasTerminalSession ? .session : .oneHour
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch prompt {
            case .strict:
                header
                requestInfo
                statedReasonSection
                callerDetailsSection
                strictDurationPicker
                strictButtons
            case .service:
                serviceHeader
                serviceRequestCard
                statedReasonSection
                callerDetailsSection
                serviceButtons
            }

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
        .authorizationPanel(width: 420, maxHeight: Self.availableHeight)
    }

    private func startSettleTimer() {
        guard !canApprove else { return }
        let remaining = ApprovalReadiness.settleDelay - Date().timeIntervalSince(shownAt)
        guard remaining > 0 else { canApprove = true; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { canApprove = true }
    }

    /// What the screen can actually show, leaving room for the menu bar and a margin.
    static var availableHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(360, visible - 80)
    }

    /// The caller's name, treated as hostile text like everything else in this window.
    ///
    /// 【安全审计 2026-09-13】6bff4fd hardened the credential label in this very sentence but
    /// left the caller name on the weaker filter — which strips control characters and nothing
    /// else, so zero-width and bidi characters went straight into the bold headline.
    private var callerName: String {
        let raw = prompt.callerIdentity?.displayName ?? L("Unknown Caller")
        let line = CallerStatedReason.printableLine(raw, limit: 80)
        return line.isEmpty ? L("Unknown Caller") : line
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("\(callerName) wants to use \(prompt.credentialLabel)"))
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(prompt.title)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var requestInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow(L("Credential"), value: prompt.credentialLabel, bold: true)
            infoRow(L("Keys"), value: prompt.fieldNames.joined(separator: ", "), monospaced: true)

            if let sessionLabel = prompt.sessionLabel {
                infoRow(L("From"), value: AppL10n.text(sessionLabel))
            }

            if let caller = prompt.callerIdentity {
                infoRow(L("Caller"), value: callerName)
                callerAssuranceRow(CallerAssurance.of(caller.subject))
            }
            // Subject fingerprint, PID and the process chain are diagnostics; they live
            // in the collapsible "Caller Details" section below.
        }
        .padding(14)
        .glassCard()
    }

    /// What is actually known about the asker, next to its name.
    private func callerAssuranceRow(_ assurance: CallerAssurance) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: assurance.symbolName)
                .foregroundColor(assurance.isReassuring ? .secondary : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(assurance.label).font(.caption.weight(.semibold))
                Text(assurance.explanation)
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func infoRow(_ label: String,
                         value: String,
                         bold: Bool = false,
                         monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(rowFont(bold: bold, monospaced: monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func rowFont(bold: Bool, monospaced: Bool) -> Font {
        if monospaced { return .subheadline.monospaced() }
        if bold { return .subheadline.bold() }
        return .subheadline
    }

    /// What the caller wrote about this request. It sits below the facts KeyKeeper verified
    /// and above the diagnostics, is plain text with no emphasis of its own, and says plainly
    /// that nobody checked it — the process that wants the value is the one that wrote it.
    @ViewBuilder
    private var statedReasonSection: some View {
        if let reason = prompt.statedReason {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "quote.bubble")
                    Text(L("What the caller says"))
                    Text(L("not verified"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Text(verbatim: reason.text)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Text(reason.truncated
                     ? L("Cut off at \(CallerStatedReason.maximumLength) characters. Written by the process asking for the key; KeyKeeper doesn't check it and it doesn't limit what allowing grants.")
                     : L("Written by the process asking for the key. KeyKeeper doesn't check it, and it doesn't limit what allowing grants."))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.card)
        }
    }

    private var strictDurationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Grant access for:"))
                .font(.subheadline.bold())

            Picker(L("Duration"), selection: $selectedDuration) {
                ForEach(DurationOption.available(hasTerminalSession: prompt.hasTerminalSession), id: \.self) { option in
                    Text(AppL10n.text(option.rawValue)).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            // What an approval actually covers, next to the choice — a caller's note may
            // promise "just one field, just once", but the grant is per credential.
            Text(L("Allowing lets \(callerName) read every key in this credential — only \(callerName), not other programs on this Mac. \u{201C}Always allow\u{201D} also covers its future sessions, until you revoke it."))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !prompt.hasTerminalSession {
                Text(L("This caller has no terminal session (cron, IDE or SDK), so a per-session grant isn't available."))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var strictButtons: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(L("Deny")) {
                onDeny()
            }
            .keyboardShortcut(.escape)

            Button(action: {
                authenticate {
                    try onAuthorizeGrant?(selectedDuration.grantDuration)
                }
            }) {
                HStack(spacing: 4) {
                    if isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: authenticationMethod.symbolName)
                    }
                    Text(L("Authorize"))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAuthenticating || !canApprove)
        }
        .controlSize(.large)
        .onAppear { startSettleTimer() }
    }

    // MARK: - Service Mode

    private var serviceHeader: some View {
        HStack(spacing: 14) {
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
            VStack(alignment: .leading, spacing: 3) {
                Text(L("\(callerName) wants to use \(prompt.credentialLabel)"))
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(prompt.title)
                    .font(.callout)
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

    private var serviceRequestCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            infoRow(L("Credential"), value: prompt.credentialLabel, bold: true)
            infoRow(L("Keys"), value: prompt.fieldNames.joined(separator: ", "), monospaced: true)
        }
        .padding(14)
        .glassCard()
    }

    @ViewBuilder
    private var callerDetailsSection: some View {
        if let caller = prompt.callerIdentity {
            DisclosureGroup(isExpanded: $showCallerDetails) {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
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
                            Text(processChainText(caller.parentChain))
                                .font(.caption.monospaced())
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.top, DS.Spacing.xs)
            } label: {
                Label(L("Caller Details"), systemImage: "info.circle")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.8))
                .frame(width: 52, alignment: .trailing)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var serviceButtons: some View {
        VStack(spacing: DS.Spacing.md) {
            Text(L("Grant this caller access for:"))
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            // The strict window has said this since 863d53e; this one never did, and "Always"
            // means the same thing in both.
            Text(L("Allowing lets \(callerName) read this key — only \(callerName), not other programs on this Mac. \u{201C}Always\u{201D} lasts until you revoke it."))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button(role: .destructive) {
                    onDeny()
                } label: {
                    Text(L("Deny"))
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)

                Spacer()

                HStack(spacing: DS.Spacing.sm) {
                    Button(L("Once")) {
                        authenticate {
                            try onAuthorizeService?(.once)
                        }
                    }
                    .disabled(isAuthenticating || !canApprove)

                    Button(L("1 Hour")) {
                        authenticate {
                            try onAuthorizeService?(.timed(Date().addingTimeInterval(3600)))
                        }
                    }
                    .disabled(isAuthenticating || !canApprove)

                    Button {
                        authenticate {
                            try onAuthorizeService?(.always)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isAuthenticating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: authenticationMethod.symbolName)
                            }
                            Text(L("Always"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAuthenticating || !canApprove)
                }
            }
        }
        .onAppear { startSettleTimer() }
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
