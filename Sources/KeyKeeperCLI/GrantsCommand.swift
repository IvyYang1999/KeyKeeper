import ArgumentParser
import Foundation
import KeyKeeperCore

/// Approvals live in a Keychain item only the app can open; this asks the app.
struct GrantsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grants",
        abstract: "List or revoke approvals (which callers may use which keys)",
        subcommands: [List.self, Revoke.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List approvals"
        )

        @Option(name: .long, help: "Filter by credential ID.")
        var credential: String?

        func run() throws {
            let reply = try IPCClient.listApprovals(credentialId: credential)
            print("Background reads by callers nobody approved yet: \(reply.mode == .permissive ? "allowed (permissive)" : "ask first (enforced)")")
            let approvals = reply.approvals.sorted { $0.createdAt > $1.createdAt }
            guard !approvals.isEmpty else { print("No approvals."); return }
            print()
            for approval in approvals {
                print(approval.id)
                switch approval.target {
                case .credential(let id, let fields):
                    print("  credential: \(id)")
                    print("  fields: \(fields?.joined(separator: ", ") ?? "all secret fields")")
                case .session(let id):
                    print("  website login: \(id)")
                }
                print("  caller: \(CallerStatedReason.printableLine(approval.subject.displayName, limit: 80))")
                print("  fingerprint: \(approval.subject.fingerprint)")
                print("  duration: \(durationLabel(approval.duration))")
                print("  created: \(formatDate(approval.createdAt))")
                if let lastUsedAt = approval.lastUsedAt { print("  last used: \(formatDate(lastUsedAt))") }
                if approval.consumed { print("  spent") }
                print()
            }
        }
    }

    struct Revoke: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "revoke",
            abstract: "Revoke an approval"
        )

        @Argument(help: "Approval ID (from grants list).")
        var id: String

        func run() throws {
            try IPCClient.revokeApproval(id: id)
            print("Revoked approval \(id)")
        }
    }
}

private func durationLabel(_ duration: ApprovalDuration) -> String {
    switch duration {
    case .once: return "once"
    case .terminalSession(let id): return "terminal session \(id.prefix(8))"
    case .timed(let expiration): return "until \(formatDate(expiration))"
    case .always: return "always"
    }
}

private func formatDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
