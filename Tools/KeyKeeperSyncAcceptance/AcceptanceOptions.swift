#if KEYKEEPER_SYNC_ACCEPTANCE
import Foundation

enum AcceptanceFailure: String, Error {
    case arguments = "invalid_arguments"
    case isolation = "isolation_guard_failed"
    case state = "unexpected_fixture_state"
    case digest = "expected_digest_mismatch"
    case sync = "sync_not_confirmed"
    case grants = "local_grant_boundary_failed"
    case cas = "stale_cas_not_rejected"
}

struct AcceptanceOptions {
    let command: String
    let runID: UUID
    let clientID: UUID
    let expectedDigest: String?
    var directory: URL {
        URL(fileURLWithPath: "/private/tmp/keykeeper-product-sync-\(runID.uuidString)-\(clientID.uuidString)", isDirectory: true)
    }

    init(_ args: [String], environment: [String: String]) throws {
        guard !environment.keys.contains(where: { $0.hasPrefix("KEYKEEPER_") }),
              args.count == 5 || args.count == 7,
              ["plan", "seed", "advance", "verify", "inspect"].contains(args[0]),
              args[1] == "--run-id", let run = UUID(uuidString: args[2]), run.uuidString == args[2],
              args[3] == "--client-id", let client = UUID(uuidString: args[4]), client.uuidString == args[4]
        else { throw AcceptanceFailure.arguments }
        command = args[0]; runID = run; clientID = client
        if command == "plan" {
            guard args.count == 5 else { throw AcceptanceFailure.arguments }
            expectedDigest = nil
        } else {
            guard args.count == 7, args[5] == "--expect-digest", args[6].count == 64,
                  args[6].allSatisfy({ "0123456789abcdef".contains($0) }) else { throw AcceptanceFailure.arguments }
            expectedDigest = args[6]
        }
    }

    static func selfTest() throws {
        let run = UUID().uuidString, client = UUID().uuidString
        let valid = ["seed", "--run-id", run, "--client-id", client, "--expect-digest", String(repeating: "a", count: 64)]
        guard try Self(valid, environment: [:]).runID.uuidString == run else { throw AcceptanceFailure.state }
        let invalid = [[String](), Array(valid.dropLast()), valid + ["--force"],
                       ["seed", "--run-id", "invalid", "--client-id", client, "--expect-digest", valid[6]],
                       ["plan", "--run-id", run, "--client-id", client, "--expect-digest", valid[6]],
                       ["seed", "--run-id", run, "--client-id", client, "--expect-digest", "ABC"]]
        for args in invalid {
            do { _ = try Self(args, environment: [:]); throw AcceptanceFailure.state }
            catch AcceptanceFailure.arguments { }
        }
        do { _ = try Self(valid, environment: ["KEYKEEPER_DATA_DIR": "/tmp/unsafe"]); throw AcceptanceFailure.state }
        catch AcceptanceFailure.arguments { }
        let options = try Self(valid, environment: [:])
        guard options.directory.path == "/private/tmp/keykeeper-product-sync-\(run)-\(client)" else { throw AcceptanceFailure.state }
    }
}
#endif
