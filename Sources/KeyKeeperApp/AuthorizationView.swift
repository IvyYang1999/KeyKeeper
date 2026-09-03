import SwiftUI
import LocalAuthentication
import KeyKeeperCore

enum AuthorizationPrompt {
    case strict(AuthRequest)
    case service(IPCServer.PendingServiceRequest)

    var title: String {
        switch self {
        case .strict:
            return "Authorization Request"
        case .service:
            return "Service Authorization Request"
        }
    }

    var credentialLabel: String {
        switch self {
        case .strict(let request):
            return request.credentialLabel
        case .service(let request):
            return request.credentialLabel
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
    private let authenticationMethod: AuthenticationMethod

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
        VStack(spacing: 20) {
            switch prompt {
            case .strict:
                header
                requestInfo
                callerDetailsSection
                strictDurationPicker
                strictButtons
            case .service:
                serviceHeader
                serviceRequestCard
                callerDetailsSection
                serviceButtons
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(24)
        .frame(width: 390)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 32))
                .foregroundColor(.accentColor)

            Text(prompt.title)
                .font(.headline)
        }
    }

    private var requestInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("Credential", value: prompt.credentialLabel, bold: true)
            infoRow("Keys", value: prompt.fieldNames.joined(separator: ", "), monospaced: true)

            if let sessionLabel = prompt.sessionLabel {
                infoRow("From", value: sessionLabel)
            }

            if let caller = prompt.callerIdentity {
                infoRow("Caller", value: caller.displayName)
            }
            // Subject fingerprint, PID and the process chain are diagnostics; they live
            // in the collapsible "Caller Details" section below.
        }
        .padding()
        .background(DS.Fill.card)
        .cornerRadius(DS.Radius.md)
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

    private var strictDurationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Grant access for:")
                .font(.subheadline.bold())

            Picker("Duration", selection: $selectedDuration) {
                ForEach(DurationOption.available(hasTerminalSession: prompt.hasTerminalSession), id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.radioGroup)

            if !prompt.hasTerminalSession {
                Text("This caller has no terminal session (cron, IDE or SDK), so a per-session grant isn't available.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var strictButtons: some View {
        HStack(spacing: 12) {
            Button("Deny") {
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
                    Text("Authorize")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAuthenticating)
            .keyboardShortcut(.return)
        }
    }

    // MARK: - Service Mode

    private var serviceHeader: some View {
        VStack(spacing: DS.Spacing.sm) {
            callerKindIcon

            Text(prompt.callerIdentity?.displayName ?? "Unknown Caller")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("requests access to")
                .font(.subheadline)
                .foregroundColor(.secondary)
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
            infoRow("Credential", value: prompt.credentialLabel, bold: true)
            infoRow("Keys", value: prompt.fieldNames.joined(separator: ", "), monospaced: true)
        }
        .padding()
        .background(DS.Fill.card)
        .cornerRadius(DS.Radius.md)
    }

    @ViewBuilder
    private var callerDetailsSection: some View {
        if let caller = prompt.callerIdentity {
            DisclosureGroup(isExpanded: $showCallerDetails) {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    if let path = caller.executablePath {
                        detailRow("Path", value: path)
                    }
                    if let bundle = caller.bundleIdentifier {
                        detailRow("Bundle", value: bundle)
                    }
                    if let team = caller.teamIdentifier {
                        detailRow("Team ID", value: team)
                    }
                    if let signing = caller.signingIdentifier {
                        detailRow("Signing", value: signing)
                    }
                    detailRow("Subject", value: shortFingerprint(caller.subjectFingerprint))
                    detailRow("PID", value: "\(caller.peerPID)")

                    if caller.parentChain.count > 1 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Process Chain")
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
                Label("Caller Details", systemImage: "info.circle")
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
            Text("Grant this caller access for:")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button(role: .destructive) {
                    onDeny()
                } label: {
                    Text("Deny")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)

                Spacer()

                HStack(spacing: DS.Spacing.sm) {
                    Button("Once") {
                        authenticate {
                            try onAuthorizeService?(.once)
                        }
                    }
                    .disabled(isAuthenticating)

                    Button("1 Hour") {
                        authenticate {
                            try onAuthorizeService?(.timed(Date().addingTimeInterval(3600)))
                        }
                    }
                    .disabled(isAuthenticating)

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
                            Text("Always")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAuthenticating)
                    .keyboardShortcut(.return)
                }
            }
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

        isAuthenticating = true
        errorMessage = nil

        let context = LAContext()
        context.evaluatePolicy(policy,
                               localizedReason: "Authorize access to \"\(prompt.credentialLabel)\"") { success, authError in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    finishAuthorization(completion)
                } else if (authError as? LAError)?.code == .userFallback ||
                          (authError as? LAError)?.code == .biometryNotAvailable {
                    // User chose password or biometry unavailable — authorize from UI
                    finishAuthorization(completion)
                } else if (authError as? LAError)?.code == .userCancel {
                    errorMessage = "Cancelled"
                } else {
                    errorMessage = authError?.localizedDescription ?? "Authentication failed"
                }
            }
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
