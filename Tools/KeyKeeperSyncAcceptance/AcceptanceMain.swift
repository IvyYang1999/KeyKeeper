import Foundation
import Darwin
#if KEYKEEPER_SYNC_ACCEPTANCE
import KeyKeeperCore
#endif

@main
enum KeyKeeperSyncAcceptance {
    static func main() async {
        #if KEYKEEPER_SYNC_ACCEPTANCE
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180) {
            print("FAIL process_deadline_no_automatic_retry")
            fflush(stdout)
            _exit(124)
        }
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["self-test"] {
                try AcceptanceOptions.selfTest()
                try AcceptanceFixture.selfTest()
                print("PASS argument_admission distinct_metadata_and_value no_native_io")
            } else {
                let options = try AcceptanceOptions(args, environment: ProcessInfo.processInfo.environment)
                if options.command == "plan" {
                    print("SEED_EXPECT=\(try AcceptanceFixture.digest(AcceptanceFixture.empty()))")
                    print("ADVANCE_EXPECT=\(try AcceptanceFixture.digest(AcceptanceFixture.snapshot(runID: options.runID, advanced: false)))")
                    print("VERIFY_EXPECT=\(try AcceptanceFixture.digest(AcceptanceFixture.snapshot(runID: options.runID, advanced: true)))")
                } else {
                    try await AcceptanceExchange.run(options)
                }
            }
        } catch {
            let code = (error as? AcceptanceFailure)?.rawValue
                ?? (error as? CloudSyncError).map { "sync_" + $0.rawValue }
                ?? "operation_failed"
            print("FAIL \(code)")
            exit(2)
        }
        #else
        print("FAIL acceptance_build_required")
        exit(78)
        #endif
    }
}
