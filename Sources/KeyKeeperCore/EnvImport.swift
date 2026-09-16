import Foundation

// yyt 2026-09-16: "vibecoder 手里有的就是 .env". Moving a project's plaintext .env into
// KeyKeeper is the one import a vibe coder actually needs. The agent names the file; the App
// reads it, shows the variable NAMES for approval, and stores the values. Nothing but names
// and counts ever goes back over the socket.

/// One `keykeeper import <path>` from a caller: the file to read and the credential to create.
public struct EnvImportRequest: Codable, Sendable, Equatable {
    public var credentialId: String
    public var filePath: String
    /// Shown as the credential's name; defaults to the id.
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

    /// Only dotenv-style files: `.env`, `.env.local`, `staging.env`. Anything else is not
    /// something an agent should be pointing KeyKeeper at.
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

/// The dotenv grammar people actually write: `KEY=value`, `export KEY=value`, single or double
/// quotes, `#` comments, blank lines. Later duplicates win, like dotenv loaders. No expansion
/// of `${OTHER}` — a value is stored exactly as written.
public enum EnvFileParser {
    public static func parse(_ text: String) -> [EnvEntry] {
        var byName: [String: EnvEntry] = [:]
        var order: [String] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard isValidName(name) else { continue }
            let value = unquote(String(line[line.index(after: equals)...]))
            if byName[name] == nil { order.append(name) }
            byName[name] = EnvEntry(name: name, value: value, line: index + 1)
        }
        return order.compactMap { byName[$0] }
    }

    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil
    }

    /// Quotes wrap the whole value; a trailing ` # comment` only counts outside quotes.
    static func unquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where trimmed.hasPrefix(quote) {
            if let end = trimmed.dropFirst().firstIndex(of: Character(quote)) {
                var inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
                if quote == "\"" { inner = inner.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"") }
                return inner
            }
            return String(trimmed.dropFirst())
        }
        if let hash = trimmed.range(of: " #") { return String(trimmed[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return trimmed
    }
}

/// Which variables become fields, under which names, and which are secrets. Decided from
/// names and from a value's *shape* only; the plan carries no values.
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

    /// Words that mark a secret by name. A URL with `user:password@` in it is a secret whatever it is called.
    static let secretWords = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PRIVATE", "CREDENTIAL",
                              "AUTH", "DSN", "SIGNING", "CERT", "SALT", "PASS"]

    public static func isSecretName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return secretWords.contains { upper.contains($0) }
    }

    public static func looksLikeSecretValue(_ value: String) -> Bool {
        if value.range(of: #"://[^/\s]+:[^/\s]+@"#, options: .regularExpression) != nil { return true }
        return value.count >= 20 && !value.contains(" ") && value.range(of: #"^[A-Za-z0-9+/=_\-.:]+$"#, options: .regularExpression) != nil
            && value.rangeOfCharacter(from: .decimalDigits) != nil && value.rangeOfCharacter(from: .letters) != nil
    }

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
            fields.append(.init(name: entry.name, fieldName: fieldName,
                                secret: isSecretName(entry.name) || looksLikeSecretValue(entry.value)))
        }
        return EnvImportPlan(fields: fields, skipped: skipped)
    }
}
