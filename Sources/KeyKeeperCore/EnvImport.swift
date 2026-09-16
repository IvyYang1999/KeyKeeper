import Foundation

/// The Agent supplies only a path and destination. The App previews names and, after
/// confirmation, imports values without handing them back over IPC.
public struct EnvImportRequest: Codable, Sendable, Equatable {
    public var credentialId: String
    public var filePath: String
    public var label: String?
    public var intent: UsageIntent?
    public var security: SecurityLevel?
    public static let maximumBytes = 65_536

    public init(credentialId: String, filePath: String, label: String? = nil,
                intent: UsageIntent? = nil, security: SecurityLevel? = nil) {
        self.credentialId = credentialId
        self.filePath = filePath
        self.label = label
        self.intent = intent
        self.security = security
    }

    public static func looksLikeEnvFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env")
    }

    public func validate() throws {
        guard CredentialNames.isValidGroupId(credentialId) else { throw ClipboardSaveError.invalidTarget }
        guard filePath.hasPrefix("/"), filePath.utf8.count <= 4096, Self.looksLikeEnvFile(filePath),
              !filePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ClipboardSaveError.invalidEnvFile
        }
        if let label, label.trimmingCharacters(in: .whitespaces).isEmpty || label.utf8.count > 200 {
            throw ClipboardSaveError.invalidTarget
        }
    }
}

public struct EnvEntry: Equatable, Sendable {
    public var name: String
    public var value: String
    public var line: Int
    public init(name: String, value: String, line: Int) { self.name = name; self.value = value; self.line = line }
}

/// Single-line dotenv assignments, quotes, comments and optional export prefix. Later
/// duplicates win. No shell expansion. Malformed or multiline syntax fails the whole import.
public enum EnvFileParser {
    public static func parse(_ text: String) throws -> [EnvEntry] {
        var byName: [String: EnvEntry] = [:]
        var order: [String] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { throw ClipboardSaveError.invalidEnvFile }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard isValidName(name) else { throw ClipboardSaveError.invalidEnvFile }
            let value = try unquote(String(line[line.index(after: equals)...]))
            if byName[name] == nil { order.append(name) }
            byName[name] = EnvEntry(name: name, value: value, line: index + 1)
        }
        return order.compactMap { byName[$0] }
    }

    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil
    }

    static func unquote(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let quote = trimmed.first, quote == "\"" || quote == "'" {
            var result = ""
            var index = trimmed.index(after: trimmed.startIndex)
            while index < trimmed.endIndex {
                let character = trimmed[index]
                index = trimmed.index(after: index)
                if character == quote {
                    let rest = trimmed[index...].trimmingCharacters(in: .whitespaces)
                    guard rest.isEmpty || rest.hasPrefix("#") else { throw ClipboardSaveError.invalidEnvFile }
                    return result
                }
                if quote == "\"", character == "\\" {
                    guard index < trimmed.endIndex else { throw ClipboardSaveError.invalidEnvFile }
                    let escaped = trimmed[index]
                    index = trimmed.index(after: index)
                    switch escaped {
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "\"", "\\": result.append(escaped)
                    default: result.append("\\"); result.append(escaped)
                    }
                } else {
                    result.append(character)
                }
            }
            throw ClipboardSaveError.invalidEnvFile
        }
        if let hash = trimmed.range(of: #"\s+#"#, options: .regularExpression) {
            return String(trimmed[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}

/// All imported values are protected. Names and shapes cannot prove a value is safe
/// to expose through metadata. The plan contains no values.
public struct EnvImportPlan: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var name: String
        public var fieldName: String
        public var secret: Bool
    }
    public struct Skipped: Equatable, Sendable {
        public var name: String
        public var reason: String
    }
    public var fields: [Field]
    public var skipped: [Skipped]
    public var secretNames: [String] { fields.filter(\.secret).map(\.name) }
    public var plainNames: [String] { fields.filter { !$0.secret }.map(\.name) }
    public var isEmpty: Bool { fields.isEmpty }

    public static func make(_ entries: [EnvEntry]) -> EnvImportPlan {
        var fields: [Field] = []
        var skipped: [Skipped] = []
        var taken = Set<String>()
        for entry in entries {
            let fieldName = entry.name.lowercased().replacingOccurrences(of: "_", with: "-")
            guard !entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skipped.append(.init(name: entry.name, reason: "empty")); continue
            }
            guard entry.value.utf8.count <= 65_536 else {
                skipped.append(.init(name: entry.name, reason: "too long")); continue
            }
            guard CredentialNames.isValidFieldName(fieldName),
                  EnvironmentVariableName.from(fieldName: fieldName, prefix: "") == entry.name else {
                skipped.append(.init(name: entry.name, reason: "name cannot round-trip to a field")); continue
            }
            guard !EnvironmentVariableName.isReserved(fieldName: fieldName) else {
                skipped.append(.init(name: entry.name, reason: "reserved variable")); continue
            }
            guard !taken.contains(fieldName) else {
                skipped.append(.init(name: entry.name, reason: "duplicate field name")); continue
            }
            taken.insert(fieldName)
            fields.append(.init(name: entry.name, fieldName: fieldName, secret: true))
        }
        return EnvImportPlan(fields: fields, skipped: skipped)
    }
}
