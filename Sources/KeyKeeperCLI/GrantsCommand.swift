import ArgumentParser
import Foundation
import KeyKeeperCore

struct GrantsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grants",
        abstract: "List or revoke service caller grants",
        subcommands: [List.self, Revoke.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List service caller grants"
        )

        @Option(name: .long, help: "Filter by credential ID.")
        var credential: String?

        func run() throws {
            let store = ServiceGrantStore.default
            let grants = try store.grants(credentialId: credential)
                .sorted { lhs, rhs in
                    lhs.createdAt > rhs.createdAt
                }

            if grants.isEmpty {
                print("No service grants.")
                return
            }

            for grant in grants {
                print("\(grant.id)")
                print("  credential: \(grant.credentialId)")
                print("  caller: \(grant.subjectDisplayName)")
                print("  fingerprint: \(grant.subjectFingerprint)")
                print("  fields: \(grant.fields.joined(separator: ", "))")
                print("  duration: \(durationLabel(grant.duration))")
                print("  created: \(formatDate(grant.createdAt))")
                if let lastUsedAt = grant.lastUsedAt {
                    print("  last used: \(formatDate(lastUsedAt))")
                }
                print()
            }
        }
    }

    struct Revoke: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "revoke",
            abstract: "Revoke a service caller grant"
        )

        @Argument(help: "Service grant ID.")
        var id: String

        func run() throws {
            try ServiceGrantStore.default.revokeGrant(id: id)
            print("Revoked service grant \(id)")
        }
    }
}

private func durationLabel(_ duration: ServiceGrantDuration) -> String {
    switch duration {
    case .once:
        return "once"
    case .timed(let expiration):
        return "until \(formatDate(expiration))"
    case .always:
        return "always"
    }
}

private func formatDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
