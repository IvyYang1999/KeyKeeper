import Foundation
import KeyKeeperCore

/// Resolve the entire mapping before grants, value reads or creating plaintext files.
struct FileInjectionPlan {
    private var names: [String: String] = [:]
    var hasFiles: Bool { !names.isEmpty }

    init(credentials: [String], mappings: [String], prefix: String, meta: MetaFile) throws {
        guard mappings.count <= 32 else { throw CommandFailure("At most 32 credential files can be injected per run.") }
        var usedNames = Set<String>()
        for mapping in mappings {
            let parts = mapping.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw CommandFailure("Use --file credential-id:field=ENV_NAME.") }
            let target = parts[0].split(separator: ":", omittingEmptySubsequences: false)
            let name = String(parts[1])
            guard target.count == 2, Self.validEnvironmentName(name),
                  !["PATH", "HOME", "TMPDIR", "SHELL", "ENV", "BASH_ENV"].contains(name),
                  !name.hasPrefix("DYLD_"), !name.hasPrefix("LD_") else {
                throw CommandFailure("Invalid credential file mapping or reserved environment variable.")
            }
            // Earlier group IDs and field names resolve to the current ones.
            let id = meta.resolveGroupId(String(target[0])) ?? String(target[0])
            let field = meta.credentials[id]?.resolveFieldName(String(target[1])) ?? String(target[1])
            let key = "\(id):\(field)"
            guard credentials.contains(id), let entry = meta.credentials[id]?.fields[field],
                  entry.secret, entry.fileFormat != nil, names[key] == nil,
                  usedNames.insert(name).inserted else {
                throw CommandFailure("File mappings must name distinct file fields in the requested -c credentials and distinct environment variables.")
            }
            names[key] = name
        }
        for id in credentials {
            guard let credential = meta.credentials[id] else { throw CommandFailure("Credential not found. Check its ID with keykeeper list.") }
            for (field, entry) in credential.fields where entry.secret {
                if entry.fileFormat != nil {
                    guard names["\(id):\(field)"] != nil else {
                        throw CommandFailure("Credential contains a file. Add --file credential-id:field=ENV_NAME; file contents are never implicitly injected as text.")
                    }
                } else if !usedNames.insert(prefix + EnvironmentVariableName.from(fieldName: field)).inserted {
                    throw CommandFailure("Environment variable conflict between credential fields.")
                }
            }
        }
    }

    func environmentName(credential: String, field: String) -> String? { names["\(credential):\(field)"] }

    private static func validEnvironmentName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, first == 95 || (65...90).contains(first), bytes.count <= 128 else { return false }
        return bytes.allSatisfy { $0 == 95 || (65...90).contains($0) || (48...57).contains($0) }
    }
}
