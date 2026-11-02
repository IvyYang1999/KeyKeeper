import Darwin
import Foundation
import Security

struct ProbeContext {
    let root: URL
    let runID: String
    let team: String
    var source: String { "com.keykeeper.test.\(runID).identity-old.values" }
    var integrity: String { "com.keykeeper.test.\(runID).identity-old.integrity" }
    var target: String { "com.keykeeper.test.\(runID).identity-new.values" }

    init(arguments: [String]) throws {
        guard arguments.count.isMultiple(of: 2) else { throw ProbeFailure.isolation }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard ["--root", "--run-id", "--team", "--receiver"].contains(arguments[index]),
                  options[arguments[index]] == nil else { throw ProbeFailure.isolation }
            options[arguments[index]] = arguments[index + 1]
        }
        guard let path = options["--root"], let id = options["--run-id"],
              UUID(uuidString: id)?.uuidString == id, let team = options["--team"],
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw ProbeFailure.isolation
        }
        // Foundation may abbreviate an existing /private/tmp URL back to /tmp.
        // Admission needs the physical path, not that display normalization.
        guard let pointer = realpath(path, nil) else { throw ProbeFailure.isolation }
        let physicalPath = String(cString: pointer)
        free(pointer)
        // Deliberately narrow admission: no user data directory or File Provider location.
        guard physicalPath == "/private/tmp/keykeeper-identity-\(id)",
              path == physicalPath else { throw ProbeFailure.isolation }
        let attributes = try FileManager.default.attributesOfItem(atPath: physicalPath)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw ProbeFailure.isolation }
        self.root = URL(fileURLWithPath: physicalPath); self.runID = id; self.team = team
    }

    var childArguments: [String] { ["consumer", "--root", root.path, "--run-id", runID, "--team", team] }

    static func selfTest() throws {
        let runID = UUID().uuidString
        let path = "/private/tmp/keykeeper-identity-\(runID)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let arguments = ["--root", path, "--run-id", runID, "--team", "ZPTA4LP594"]
        let context = try ProbeContext(arguments: arguments)
        guard context.root.path == path, context.runID == runID else { throw ProbeFailure.isolation }
        var alias = arguments
        alias[1] = "/tmp/keykeeper-identity-\(runID)"
        var refusedAlias = false
        do { _ = try ProbeContext(arguments: alias) } catch { refusedAlias = true }
        var wrongID = arguments
        wrongID[3] = UUID().uuidString
        var refusedID = false
        do { _ = try ProbeContext(arguments: wrongID) } catch { refusedID = true }
        guard refusedAlias, refusedID else { throw ProbeFailure.isolation }
        print("PASS physical isolation: existing directory accepted; path alias and mismatched run ID refused")
    }
}

enum ProbeIdentity {
    static func requirement(identifier: String, team: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw ProbeFailure.signature }
        return requirement
    }

    static func current(identifier: String, team: String) throws {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], try requirement(identifier: identifier, team: team)) == errSecSuccess else {
            throw ProbeFailure.signature
        }
    }

    static func parent(team: String) throws {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: getppid())]
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], try requirement(identifier: "com.keykeeper.app", team: team)) == errSecSuccess else {
            throw ProbeFailure.signature
        }
    }

    static func receiver(_ url: URL, team: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), try requirement(identifier: "dev.keykeeper.app", team: team)) == errSecSuccess else {
            throw ProbeFailure.signature
        }
    }
}

enum ProbeKeychain {
    static func query(service: String, context: ProbeContext) throws -> [String: Any] {
        guard [context.source, context.integrity, context.target].contains(service) else { throw ProbeFailure.isolation }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: "synthetic-identity-probe", kSecUseDataProtectionKeychain as String: false,
                kSecAttrSynchronizable as String: false, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    static func read(_ service: String, context: ProbeContext) throws -> Data? {
        var query = try query(service: service, context: context)
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess else { throw ProbeFailure.keychain(result) }
        guard let data = value as? Data else { throw ProbeFailure.rejected }
        return data
    }

    static func create(_ data: Data, service: String, context: ProbeContext) throws {
        var query = try query(service: service, context: context)
        query[kSecValueData as String] = data
        let result = SecItemAdd(query as CFDictionary, nil)
        guard result == errSecSuccess else { throw ProbeFailure.keychain(result) }
    }
}
