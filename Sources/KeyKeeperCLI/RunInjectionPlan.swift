import Foundation
import KeyKeeperCore

/// The single source of truth for what `run` will inject. It is resolved before any secret read,
/// approval request, temporary file, or child process exists, so `--plan` and execution cannot
/// disagree about names or conflicts.
struct RunInjectionPlan {
    enum Kind: String, Equatable {
        case plainText = "plain text"
        case secretText = "secret text"
        case secretFile = "secret file"
    }

    struct Binding: Equatable {
        let credentialId: String
        let fieldName: String
        let environmentName: String
        var aliasEnvironmentNames: [String]
        let kind: Kind

        var isSecret: Bool { kind != .plainText }
    }

    let bindings: [Binding]
    var hasFiles: Bool { bindings.contains { $0.kind == .secretFile } }

    private let bindingsByField: [String: Binding]

    init(credentials: [String], environmentMappings: [String], fileMappings: [String],
         prefix: String, meta: MetaFile) throws {
        guard environmentMappings.count <= 32 else {
            throw CommandFailure("At most 32 text fields can be explicitly mapped per run.")
        }
        guard fileMappings.count <= 32 else {
            throw CommandFailure("At most 32 credential files can be injected per run.")
        }

        let textNames = try Self.parseMappings(environmentMappings, kind: .text,
                                                credentials: credentials, meta: meta)
        let fileNames = try Self.parseMappings(fileMappings, kind: .file,
                                                credentials: credentials, meta: meta)
        var planned: [Binding] = []

        for id in credentials {
            guard let credential = meta.credentials[id] else {
                throw CommandFailure("Credential not found. Check its ID with keykeeper list.")
            }
            let orderedFields = credential.fields.sorted { left, right in
                let leftRank = left.value.secret ? 1 : 0
                let rightRank = right.value.secret ? 1 : 0
                return leftRank == rightRank ? left.key < right.key : leftRank < rightRank
            }
            for (field, entry) in orderedFields {
                let key = Self.key(id, field)
                let kind: Kind
                let explicitName: String?
                if entry.secret, entry.fileFormat != nil {
                    kind = .secretFile
                    guard let mapped = fileNames[key] else {
                        throw CommandFailure("Credential contains a file. Add --file for \(id):\(field); file contents are never implicitly injected as text.")
                    }
                    explicitName = mapped
                } else if entry.secret {
                    kind = .secretText
                    explicitName = textNames[key]
                } else {
                    guard entry.setByCaller == nil, entry.value?.isEmpty == false else { continue }
                    kind = .plainText
                    explicitName = textNames[key]
                }
                let name = explicitName ?? EnvironmentVariableName.from(fieldName: field, prefix: prefix)
                guard Self.validEnvironmentName(name), !EnvironmentVariableName.isReservedVariable(name) else {
                    throw CommandFailure(EnvironmentVariableName.refusalMessage(name))
                }
                planned.append(Binding(credentialId: id, fieldName: field,
                                       environmentName: name, aliasEnvironmentNames: [], kind: kind))
            }
        }

        var hardNames = Set<String>()
        for binding in planned {
            guard hardNames.insert(binding.environmentName).inserted else {
                throw CommandFailure("Environment variable conflict: '\(binding.environmentName)' would be set by multiple fields. Use --env to give each field a distinct name.")
            }
        }

        var claimedAliases = Set<String>()
        for index in planned.indices where planned[index].kind != .secretFile {
            let binding = planned[index]
            let key = Self.key(binding.credentialId, binding.fieldName)
            guard textNames[key] == nil, let credential = meta.credentials[binding.credentialId] else { continue }
            let aliases = credential.environmentNames(forField: binding.fieldName, prefix: prefix).dropFirst()
                .filter { !EnvironmentVariableName.isReservedVariable($0) && !hardNames.contains($0) }
                .filter { claimedAliases.insert($0).inserted }
            planned[index].aliasEnvironmentNames = Array(aliases)
        }

        bindings = planned
        bindingsByField = Dictionary(uniqueKeysWithValues: planned.map {
            (Self.key($0.credentialId, $0.fieldName), $0)
        })
    }

    func binding(credential: String, field: String) -> Binding? {
        bindingsByField[Self.key(credential, field)]
    }

    /// Metadata-only output. Plain values are intentionally never interpolated.
    func render(meta: MetaFile, inventory: [String: [String]]?) -> String {
        var lines = ["Run plan:"]
        for binding in bindings {
            let stored: String
            if binding.kind == .plainText {
                stored = "yes"
            } else if let inventory {
                stored = inventory[binding.credentialId]?.contains(binding.fieldName) == true ? "yes" : "no"
            } else {
                stored = "unknown (KeyKeeper app is not running)"
            }
            let access: String
            if binding.kind == .plainText {
                access = "not required"
            } else if meta.credentials[binding.credentialId]?.security == .strict {
                access = "checked at run time (Ask Every Time)"
            } else {
                access = "checked at run time (Background OK)"
            }
            let aliases = binding.aliasEnvironmentNames.isEmpty
                ? ""
                : "; aliases: " + binding.aliasEnvironmentNames.joined(separator: ", ")
            lines.append("- \(binding.credentialId):\(binding.fieldName) -> \(binding.environmentName) [\(binding.kind.rawValue); stored: \(stored); access: \(access)\(aliases)]")
        }
        if bindings.isEmpty { lines.append("- Nothing to inject.") }
        lines.append("No conflicts detected.")
        lines.append("Local storage presence does not prove caller approval or provider acceptance.")
        lines.append("No secret values were returned to the CLI. No command was started.")
        return lines.joined(separator: "\n")
    }

    private enum MappingKind { case text, file }

    private static func parseMappings(_ mappings: [String], kind: MappingKind,
                                      credentials: [String], meta: MetaFile) throws -> [String: String] {
        var names: [String: String] = [:]
        for mapping in mappings {
            let parts = mapping.split(separator: "=", omittingEmptySubsequences: false)
            let target = parts.first?.split(separator: ":", omittingEmptySubsequences: false) ?? []
            guard parts.count == 2, target.count == 2 else {
                throw CommandFailure("Use a credential ID, field name, and environment variable name in each mapping.")
            }
            let name = String(parts[1])
            guard validEnvironmentName(name), !EnvironmentVariableName.isReservedVariable(name) else {
                throw CommandFailure("Invalid mapping or reserved environment variable.")
            }
            let id = meta.resolveGroupId(String(target[0])) ?? String(target[0])
            guard credentials.contains(id), let credential = meta.credentials[id],
                  let field = credential.resolveFieldName(String(target[1])),
                  let entry = credential.fields[field] else {
                throw CommandFailure("Mappings must name fields in the requested -c credentials.")
            }
            let fieldKey = key(id, field)
            let matchesKind: Bool
            switch kind {
            case .file: matchesKind = entry.secret && entry.fileFormat != nil
            case .text:
                matchesKind = entry.fileFormat == nil
                    && (entry.secret || (entry.setByCaller == nil && entry.value?.isEmpty == false))
            }
            guard matchesKind, names[fieldKey] == nil else {
                throw CommandFailure("Mappings must name distinct injectable fields of the matching type.")
            }
            names[fieldKey] = name
        }
        return names
    }

    private static func key(_ credential: String, _ field: String) -> String { "\(credential):\(field)" }

    private static func validEnvironmentName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, first == 95 || (65...90).contains(first), bytes.count <= 128 else { return false }
        return bytes.allSatisfy { $0 == 95 || (65...90).contains($0) || (48...57).contains($0) }
    }
}
