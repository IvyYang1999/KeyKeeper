import SwiftUI
import KeyKeeperCore

/// Always-visible vault state at the top of the credential list: create, unlock, or lock.
struct SessionBanner: View {
    @ObservedObject var state: SessionStateViewModel
    @FocusState private var passphraseFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let recovery = state.recoveryIdentity {
                recoveryCard(recovery)
            } else {
                switch state.bannerState {
                case .needsVault:
                    createCard
                case .locked:
                    lockedCard
                case .unlocked(let expiresAt):
                    unlockedRow(expiresAt: expiresAt)
                }
            }
        }
    }

    // MARK: - States

    private var createCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label("Create your vault", systemImage: "lock.shield")
                .font(.callout.weight(.semibold))
            Text("Choose a passphrase. It encrypts every key you store here and never leaves this Mac.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Passphrase (8+ characters)", text: $state.passphrase)
                .textFieldStyle(.roundedBorder)
                .focused($passphraseFocused)
            SecureField("Repeat passphrase", text: $state.confirmPassphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit { state.createVault() }

            errorLine

            HStack {
                Spacer()
                Button("Create Vault") { state.createVault() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .dsCard(padding: DS.Spacing.md)
        .onAppear { passphraseFocused = true }
    }

    private var lockedCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label("Vault locked", systemImage: "lock.fill")
                .font(.callout.weight(.semibold))
                .foregroundColor(.orange)
            Text("Cron jobs, scripts and AI tools can't read keys until you unlock.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Spacing.sm) {
                SecureField("Passphrase", text: $state.passphrase)
                    .textFieldStyle(.roundedBorder)
                    .focused($passphraseFocused)
                    .onSubmit { state.unlock() }
                Button("Unlock") { state.unlock() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy)
            }

            errorLine
        }
        .dsCard(padding: DS.Spacing.md, fill: Color.orange.opacity(0.10))
        .onAppear { passphraseFocused = true }
    }

    private func unlockedRow(expiresAt: Date?) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
            Text(Self.unlockedLabel(expiresAt: expiresAt))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Lock") { state.lock() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
                .help("Lock the vault. Background jobs will fail until you unlock again.")
        }
        .padding(.horizontal, DS.Spacing.xs)
    }

    private func recoveryCard(_ recovery: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label("Save your recovery key", systemImage: "key.viewfinder")
                .font(.callout.weight(.semibold))
            Text("This is the only way back in if you forget your passphrase. KeyKeeper does not keep a copy. Store it somewhere safe, then dismiss this card.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CopyableCommand(recovery)
            HStack {
                Spacer()
                Button("I've saved it") { state.dismissRecoveryIdentity() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .dsCard(padding: DS.Spacing.md, fill: Color.yellow.opacity(0.12))
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error = state.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func unlockedLabel(expiresAt: Date?, now: Date = Date()) -> String {
        guard let expiresAt else {
            return "Unlocked until you lock or quit"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Unlocked, locks \(formatter.localizedString(for: expiresAt, relativeTo: now))"
    }
}
