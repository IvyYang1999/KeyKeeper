import SwiftUI
import LocalAuthentication
import KeyKeeperCore

struct AuthorizationView: View {
    let request: AuthRequest
    let onAuthorize: (GrantDuration) -> Void
    let onDeny: () -> Void

    @State private var selectedDuration: DurationOption = .session
    @State private var isAuthenticating = false
    @State private var errorMessage: String?

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
            // Header
            VStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)

                Text("Authorization Request")
                    .font(.headline)
            }

            // Credential info
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Credential")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(request.credentialLabel)
                        .font(.subheadline.bold())
                }

                HStack {
                    Text("Keys")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(request.fieldNames.joined(separator: ", "))
                        .font(.subheadline.monospaced())
                }

                if let sessionLabel = request.sessionLabel {
                    HStack {
                        Text("From")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(sessionLabel)
                            .font(.subheadline)
                    }
                }

                HStack {
                    Text("PID")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(request.pid)")
                        .font(.subheadline.monospaced())
                }
            }
            .padding()
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)

            // Duration picker
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

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button("Deny") {
                    onDeny()
                }
                .keyboardShortcut(.escape)

                Button(action: authenticate) {
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
        .padding(24)
        .frame(width: 360)
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?

        // Only use biometrics if available and the app can actually use them
        // (unsigned debug builds may trigger extra system prompts with LAContext)
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
              error == nil else {
            // No biometrics available — authorize directly from UI confirmation
            onAuthorize(selectedDuration.grantDuration)
            return
        }

        isAuthenticating = true
        errorMessage = nil

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                               localizedReason: "Authorize access to \"\(request.credentialLabel)\"") { success, authError in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    onAuthorize(selectedDuration.grantDuration)
                } else if (authError as? LAError)?.code == .userFallback ||
                          (authError as? LAError)?.code == .biometryNotAvailable {
                    // User chose password or biometry unavailable — authorize from UI
                    onAuthorize(selectedDuration.grantDuration)
                } else if (authError as? LAError)?.code == .userCancel {
                    errorMessage = "Cancelled"
                } else {
                    errorMessage = authError?.localizedDescription ?? "Authentication failed"
                }
            }
        }
    }
}
