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
    let onAuthorizeGrant: ((GrantDuration) -> Void)?
    let onAuthorizeService: ((ServiceGrantDuration) -> Void)?
    let onDeny: () -> Void

    @State private var selectedDuration: DurationOption = .session
    @State private var isAuthenticating = false
    @State private var errorMessage: String?
    @State private var showCallerDetails = false

    enum DurationOption: String, CaseIterable {
        case once = "Just this once"
        case session = "This session"
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
    }

    var body: some View {
        VStack(spacing: 20) {
            switch prompt {
            case .strict:
                header
                requestInfo
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
                infoRow(
                    "Subject",
                    value: shortFingerprint(caller.subjectFingerprint),
                    monospaced: true
                )
            }

            infoRow("PID", value: "\(prompt.pid)", monospaced: true)
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
                ForEach(DurationOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
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
                    onAuthorizeGrant?(selectedDuration.grantDuration)
                }
            }) {
                HStack(spacing: 4) {
                    if isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "touchid")
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
                            onAuthorizeService?(.once)
                        }
                    }
                    .disabled(isAuthenticating)

                    Button("1 Hour") {
                        authenticate {
                            onAuthorizeService?(.timed(Date().addingTimeInterval(3600)))
                        }
                    }
                    .disabled(isAuthenticating)

                    Button {
                        authenticate {
                            onAuthorizeService?(.always)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isAuthenticating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "touchid")
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

    private func authenticate(_ completion: @escaping () -> Void) {
        let context = LAContext()
        var error: NSError?

        // Only use biometrics if available and the app can actually use them
        // (unsigned debug builds may trigger extra system prompts with LAContext)
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              error == nil else {
            // No biometrics available — authorize directly from UI confirmation
            completion()
            return
        }

        isAuthenticating = true
        errorMessage = nil

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                               localizedReason: "Authorize access to \"\(prompt.credentialLabel)\"") { success, authError in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    completion()
                } else if (authError as? LAError)?.code == .userFallback ||
                          (authError as? LAError)?.code == .biometryNotAvailable {
                    // User chose password or biometry unavailable — authorize from UI
                    completion()
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
