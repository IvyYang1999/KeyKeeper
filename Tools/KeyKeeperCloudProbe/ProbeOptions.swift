import Foundation

enum ProbeFailure: String, Error {
    case invalidArguments = "invalid_probe_arguments"
    case isolation = "isolation_guard_failed"
    case identity = "signed_identity_or_entitlements_invalid"
    case account = "icloud_account_unavailable_or_changed"
    case unavailable = "cloud_operation_failed"
    case missingKey = "waiting_for_key"
    case keychain = "test_keychain_operation_failed"
    case conflict = "conflict_retained_no_overwrite"
    case pending = "pending_write_requires_readback"
    case corrupt = "invalid_test_record"
}

struct ProbeOptions {
    let command: String
    let runID: UUID
    let root: URL
    let expectedDigest: String?
    static let container = "iCloud.dev.keykeeper.app"
    static let applicationID = "ZPTA4LP594.dev.keykeeper.app"

    init(arguments: [String]) throws {
        guard arguments.count == 6 || arguments.count == 8,
              ["status", "seed", "read", "advance"].contains(arguments[0]),
              arguments[1] == "--synthetic", arguments[2] == "--run-id",
              let runID = UUID(uuidString: arguments[3]), arguments[4] == "--root",
              arguments[5].hasPrefix("/") else { throw ProbeFailure.invalidArguments }
        command = arguments[0]
        self.runID = runID
        root = URL(fileURLWithPath: arguments[5], isDirectory: true)
        if arguments.count == 8 {
            guard command == "read", arguments[6] == "--expect-digest",
                  arguments[7].count == 64, arguments[7].allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw ProbeFailure.invalidArguments
            }
            expectedDigest = arguments[7]
        } else { expectedDigest = nil }
    }

    /// Only an existing, private, purely local task directory can hold probe state.
    func validateRoot() throws {
        guard let canonical = realpath(root.path, nil) else { throw ProbeFailure.isolation }
        defer { free(canonical) }
        let resolved = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        guard resolved.path == root.path,
              !resolved.pathComponents.contains(where: {
                  ["Library", "Documents", "Desktop", "CloudStorage", "Mobile Documents"].contains($0)
              }), resolved.lastPathComponent.hasPrefix("keykeeper-cloud-"),
              resolved.path.hasPrefix("/private/tmp/") || resolved.path.hasPrefix(NSHomeDirectory() + "/Developer/")
        else { throw ProbeFailure.isolation }
        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        else { throw ProbeFailure.isolation }
        let values = try root.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey])
        guard values.isUbiquitousItem != true, values.volumeIsLocal == true else { throw ProbeFailure.isolation }
    }

    static func selfTest() throws {
        let id = UUID().uuidString
        let valid = ["status", "--synthetic", "--run-id", id, "--root", "/private/tmp/keykeeper-cloud-test"]
        guard try Self(arguments: valid).runID.uuidString == id else { throw ProbeFailure.corrupt }
        for bad in [Array(valid.dropFirst()), ["status"],
                    ["seed", "--production", "--run-id", id, "--root", "/private/tmp/keykeeper-cloud-test"],
                    ["seed", "--synthetic", "--run-id", "not-a-uuid", "--root", "/private/tmp/keykeeper-cloud-test"],
                    ["seed", "--synthetic", "--run-id", id, "--root", "relative"], valid + ["--force"]] {
            do { _ = try Self(arguments: bad); throw ProbeFailure.corrupt }
            catch ProbeFailure.invalidArguments { }
        }
    }
}
