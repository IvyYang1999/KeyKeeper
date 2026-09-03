import ArgumentParser
import Foundation
import KeyKeeperCore

/// There is no unlock/lock any more: the keychain opens with the user's login
/// (decision 2026-09-03). `status` only reports whether the app is reachable.
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether the KeyKeeper app is reachable"
    )

    func run() throws {
        print(Self.report(
            query: { try IPCClient.requestSessionControl(
                SessionControlRequest(action: .status),
                launchIfNeeded: false
            ) }
        ))
    }

    /// Pure so it can be tested without a socket.
    static func report(query: () throws -> SessionControlResponse) -> String {
        do {
            let response = try query()
            guard response.success else {
                return "app responded with an error\(response.error.map { ": \($0)" } ?? "")"
            }
            return "ready"
        } catch IPCError.appNotRunning {
            return "app not running (it starts automatically when a key is requested)"
        } catch {
            return "app not reachable: \(error.localizedDescription)"
        }
    }
}
