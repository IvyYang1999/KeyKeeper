import ArgumentParser
import Foundation
import KeyKeeperCore

struct RequestsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "requests",
        abstract: "Inspect pending service authorization requests",
        subcommands: [List.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List pending service authorization requests"
        )

        func run() throws {
            do {
                let requests = try IPCClient.requestPendingServiceRequests()
                if requests.isEmpty {
                    print("No pending service requests.")
                    return
                }

                for request in requests {
                    print("\(request.id)")
                    print("  credential: \(request.credentialId) | \(request.credentialLabel)")
                    print("  caller: \(request.callerDisplayName)")
                    print("  fingerprint: \(request.subjectFingerprint)")
                    print("  fields: \(request.fieldNames.joined(separator: ", "))")
                    print("  requested: \(formatRequestDate(request.requestedAt))")
                    if request.expiresAt == .distantFuture {
                        print("  ends: when the requesting command stops or you decide")
                    } else {
                        // Older KeyKeeper apps still send a real deadline.
                        print("  expires: \(formatRequestDate(request.expiresAt))")
                    }
                    print()
                }
            } catch IPCError.appNotRunning {
                print("No pending service requests. KeyKeeper app is not running.")
            }
        }
    }
}

private func formatRequestDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
