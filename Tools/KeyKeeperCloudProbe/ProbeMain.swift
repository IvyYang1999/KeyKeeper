import Foundation
import CloudKit

@main
enum KeyKeeperCloudProbe {
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst() == ["self-test"] {
                try ProbeOptions.selfTest()
                try ProbeAccountFenceTests.run()
                try ProbeExchange.selfTest()
                print("PASS isolation arguments encrypted_exchange distinct_mutation no_grants account_epoch_fences late_callback_cancel deadline_independence; no Keychain or CloudKit IO")
            } else {
                let options = try ProbeOptions(arguments: Array(CommandLine.arguments.dropFirst()))
                try options.validateRoot()
                let directoryLock = try ProbeDirectoryLock(root: options.root)
                defer { withExtendedLifetime(directoryLock) {} }
                let identity = try ProbeIdentity()
                let cloud = ProbeCloud(identity: identity)
                let account = try await cloud.account()
                if options.command == "status" {
                    let permit = try await cloud.verify(account: account)
                    try cloud.withVerifiedAccount(permit) {
                        print("PASS signed_identity cloud_account_available environment=\(identity.environment)")
                    }
                } else {
                    try await ProbeExchange.run(options: options, cloud: cloud, account: account)
                }
            }
        } catch {
            if let error = error as? CKError { print("FAIL cloud_error_\(error.code.rawValue)") }
            else if let error = error as? ProbeKeychainStatus { print("FAIL test_keychain_status_\(error.code)") }
            else { print("FAIL \((error as? ProbeFailure)?.rawValue ?? "invalid_encrypted_state")") }
            exit(2)
        }
    }
}
