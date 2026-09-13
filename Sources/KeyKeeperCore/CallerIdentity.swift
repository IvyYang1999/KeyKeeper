import CryptoKit
import Foundation
import Security

public struct CallerIdentity: Codable, Equatable, Sendable {
    public var peerPID: Int32
    public var executablePath: String?
    public var bundleIdentifier: String?
    public var teamIdentifier: String?
    public var signingIdentifier: String?
    public var parentChain: [CallerProcess]
    public var subject: CallerSubject

    public init(peerPID: Int32,
                executablePath: String? = nil,
                bundleIdentifier: String? = nil,
                teamIdentifier: String? = nil,
                signingIdentifier: String? = nil,
                parentChain: [CallerProcess] = [],
                subject: CallerSubject) {
        self.peerPID = peerPID
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.parentChain = parentChain
        self.subject = subject
    }

    public var subjectFingerprint: String {
        subject.fingerprint
    }

    public var displayName: String {
        subject.displayName
    }
}

public struct CallerProcess: Codable, Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var executablePath: String?
    public var bundleIdentifier: String?
    public var teamIdentifier: String?
    public var signingIdentifier: String?
    public var scriptPath: String?

    public init(pid: Int32,
                parentPID: Int32,
                executablePath: String? = nil,
                bundleIdentifier: String? = nil,
                teamIdentifier: String? = nil,
                signingIdentifier: String? = nil,
                scriptPath: String? = nil) {
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.scriptPath = scriptPath
    }

    public var displayName: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        if let scriptPath, !scriptPath.isEmpty {
            return URL(fileURLWithPath: scriptPath).lastPathComponent
        }
        if let executablePath, !executablePath.isEmpty {
            return URL(fileURLWithPath: executablePath).lastPathComponent
        }
        return "pid \(pid)"
    }
}

public struct CallerSubject: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case app
        case script
        case executable
    }

    public var kind: Kind
    public var fingerprint: String
    public var displayName: String
    public var detail: String

    public init(kind: Kind, fingerprint: String, displayName: String, detail: String) {
        self.kind = kind
        self.fingerprint = fingerprint
        self.displayName = displayName
        self.detail = detail
    }

    /// Prefix for a caller whose code identity could not be established.
    ///
    /// 【安全审计 2026-09-13】Identity used to be read from the pid *after* the connection was
    /// accepted, so a process could connect, hand the socket to a sibling, and exec into a
    /// trusted app bundle — the server then measured the trusted image while the attacker held
    /// the connection. Anything not proven against the connection's own audit token now carries
    /// this prefix, and nothing with this prefix may satisfy an approval.
    public static let unverifiedPrefix = "unverified:"

    public var isVerifiedCodeIdentity: Bool { !fingerprint.hasPrefix(Self.unverifiedPrefix) }

    /// The fingerprint for a caller whose signature was actually checked. Nil unless the
    /// signing information is complete: a partial identity is not an identity.
    public static func verifiedFingerprint(teamIdentifier: String?,
                                           bundleIdentifier: String?,
                                           signingIdentifier: String?) -> String? {
        guard let team = teamIdentifier, !team.isEmpty,
              let bundle = bundleIdentifier, !bundle.isEmpty else { return nil }
        return "app:team=\(team):bundle=\(bundle):signing=\(signingIdentifier ?? bundle)"
    }

    /// What this caller is, in three tiers.
    ///
    /// A signed, valid identity is the strong case. Most agents on a developer's Mac are not
    /// that — unsigned or ad-hoc local programs — and refusing them any standing approval would
    /// mean a prompt on every single call, which is the thing people click "Always" to stop. So
    /// an unsigned caller that can still be located at connect time gets a weaker identity based
    /// on its executable path: the exec-swap trick cannot steal it, because the path is measured
    /// from the connection's own audit token. Only a caller that cannot be located at all is
    /// unverified, and that one can never hold an approval.
    public static func fingerprint(validSignature: Bool,
                                   teamIdentifier: String?,
                                   bundleIdentifier: String?,
                                   signingIdentifier: String?,
                                   mainExecutablePath: String?) -> String {
        if validSignature,
           let signed = verifiedFingerprint(teamIdentifier: teamIdentifier,
                                            bundleIdentifier: bundleIdentifier,
                                            signingIdentifier: signingIdentifier) {
            return signed
        }
        guard let path = mainExecutablePath, !path.isEmpty else {
            return unverifiedPrefix + "unlocatable"
        }
        let digest = SHA256.hash(data: Data(path.utf8))
        return "unsigned:path=" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum CallerIdentityResolver {
    /// Identity proven against the connection's own audit token.
    ///
    /// The token is taken from the socket at accept time and carries the peer's pid *and* its
    /// pidversion, so the code object it resolves to is the image that was running when the
    /// connection was made. A process that connects and then execs into a trusted app bundle
    /// still measures as itself — which is the whole point, because the alternative (reading the
    /// pid's current executable) hands anyone the identity of any signed binary on the Mac.
    ///
    /// Anything that cannot be proven comes back marked unverified, and an unverified caller
    /// matches no approval; it has to be allowed by a person, every time.
    public static func resolve(auditToken: Data, maxDepth: Int = 12) -> CallerIdentity {
        let pid = peerPID(fromAuditToken: auditToken) ?? -1
        let processes = processChain(startingAt: pid, maxDepth: maxDepth)
        let peer = processes.first
        let measured = verifiedSubject(auditToken: auditToken, pid: pid, peer: peer)
        // Our own signed CLI is a courier, not a caller. Almost every request arrives through it
        // (the SDKs shell out to it too), so identifying the courier would give every agent on
        // the Mac one shared identity — and one "Always" for all of them. The caller is upstream.
        let subject: CallerSubject
        if isOwnCLI(team: measured.team, signing: measured.signing, executable: measured.executable,
                    ownTeam: ownTeamIdentifier, ownCLIPath: ownCLIPath) {
            subject = courierUpstream(selectSubject(from: processes, peerPID: pid))
        } else {
            subject = measured.subject
        }
        return CallerIdentity(
            peerPID: pid,
            executablePath: peer?.executablePath,
            bundleIdentifier: peer?.bundleIdentifier,
            teamIdentifier: peer?.teamIdentifier,
            signingIdentifier: peer?.signingIdentifier,
            parentChain: processes,
            subject: subject
        )
    }

    static func peerPID(fromAuditToken token: Data) -> Int32? {
        guard token.count == MemoryLayout<audit_token_t>.size else { return nil }
        var value = audit_token_t()
        _ = withUnsafeMutableBytes(of: &value) { token.copyBytes(to: $0) }
        // val[5] is the pid; this is what audit_token_to_pid() reads, and reading it directly
        // avoids linking libbsm for one accessor. val[7] is the pidversion, which is what makes
        // the token immune to pid reuse — SecCode checks it for us.
        return Int32(bitPattern: value.val.5)
    }

    struct MeasuredPeer {
        let subject: CallerSubject
        let team: String?
        let signing: String?
        let executable: String?
    }

    private static func verifiedSubject(auditToken: Data, pid: Int32,
                                        peer: CallerProcess?) -> MeasuredPeer {
        func unverified(_ reason: String) -> MeasuredPeer {
            MeasuredPeer(subject: CallerSubject(kind: .executable,
                          fingerprint: CallerSubject.unverifiedPrefix + reason,
                          displayName: peer?.bundleIdentifier ?? (peer?.executablePath as NSString?)?.lastPathComponent ?? "Unknown Caller",
                          detail: peer?.executablePath ?? ""),
                         team: nil, signing: nil, executable: nil)
        }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return unverified("no-code-object") }
        // Recorded, not required: an unsigned caller still gets a (weaker) identity below.
        // Intact is not enough: a self-signed certificate can carry any team identifier and still
        // produce an intact signature. Only a chain to Apple makes the team mean something.
        let validSignature = appleAnchoredRequirement.map { SecCodeCheckValidity(code, [], $0) == errSecSuccess } ?? false
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return unverified("no-static-code") }
        var information: CFDictionary?
        let gotInfo = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                                    &information) == errSecSuccess
        let info = (gotInfo ? information as? [String: Any] : nil) ?? [:]

        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let signing = info[kSecCodeInfoIdentifier as String] as? String
        let plist = info[kSecCodeInfoPList as String] as? [String: Any]
        let bundle = plist?["CFBundleIdentifier"] as? String
        // Measured from the audit token, so this is the image that opened the connection.
        let executable = (info[kSecCodeInfoMainExecutable as String] as? URL)?.path
            ?? peer?.executablePath
        let fingerprint = CallerSubject.fingerprint(
            validSignature: validSignature, teamIdentifier: team,
            bundleIdentifier: bundle, signingIdentifier: signing, mainExecutablePath: executable)
        return MeasuredPeer(
            subject: CallerSubject(kind: bundle == nil ? .executable : .app,
                                   fingerprint: fingerprint,
                                   displayName: bundle ?? (executable as NSString?)?.lastPathComponent ?? "Unknown Caller",
                                   detail: executable ?? ""),
            team: validSignature ? team : nil, signing: validSignature ? signing : nil, executable: executable)
    }

    /// This app's own team, from its own signature. Nil for an unsigned development build.
    static let ownTeamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// The CLI shipped inside this app bundle.
    static let ownCLIPath: String = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/keykeeper").path

    /// Is the peer KeyKeeper's own CLI? Signed: same team and the CLI's signing identifier.
    /// Unsigned (a development build): exactly the file inside this bundle. A program merely
    /// *named* keykeeper, or signed by someone else, is not a courier — otherwise renaming a
    /// binary would be a way to launder its identity.
    public static func isOwnCLI(team: String?, signing: String?, executable: String?,
                                ownTeam: String?, ownCLIPath: String) -> Bool {
        if let team, let ownTeam, team == ownTeam, signing == "keykeeper" { return true }
        if let executable, !ownCLIPath.isEmpty,
           URL(fileURLWithPath: executable).standardizedFileURL.path
            == URL(fileURLWithPath: ownCLIPath).standardizedFileURL.path {
            return true
        }
        return false
    }

    /// The caller upstream of our CLI. A bare pid is not an identity anyone can hold an approval
    /// under — pids are reused — so that fallback becomes unverified.
    public static func courierUpstream(_ subject: CallerSubject) -> CallerSubject {
        guard subject.fingerprint.hasPrefix("executable:pid=") else { return subject }
        return CallerSubject(kind: subject.kind,
                             fingerprint: CallerSubject.unverifiedPrefix + "upstream-unidentified",
                             displayName: subject.displayName, detail: subject.detail)
    }

    public static func resolve(peerPID: Int32, maxDepth: Int = 12) -> CallerIdentity {
        let processes = processChain(startingAt: peerPID, maxDepth: maxDepth)
        let peer = processes.first
        let subject = selectSubject(from: processes, peerPID: peerPID)

        return CallerIdentity(
            peerPID: peerPID,
            executablePath: peer?.executablePath,
            bundleIdentifier: peer?.bundleIdentifier,
            teamIdentifier: peer?.teamIdentifier,
            signingIdentifier: peer?.signingIdentifier,
            parentChain: processes,
            subject: subject
        )
    }

    public static func selectSubject(from processes: [CallerProcess],
                                     peerPID: Int32 = 0) -> CallerSubject {
        let nonKeyKeeperProcesses = processes.filter { process in
            guard let executablePath = process.executablePath else { return true }
            return URL(fileURLWithPath: executablePath).lastPathComponent != "keykeeper"
        }

        if let app = nonKeyKeeperProcesses.first(where: { $0.bundleIdentifier != nil }) {
            let bundle = app.bundleIdentifier ?? "unknown-bundle"
            let team = app.teamIdentifier ?? "unsigned"
            let signing = app.signingIdentifier ?? bundle
            let fingerprint = "app:team=\(team):bundle=\(bundle):signing=\(signing)"
            return CallerSubject(
                kind: .app,
                fingerprint: fingerprint,
                displayName: bundle,
                detail: "team \(team), signing \(signing)"
            )
        }

        if let script = nonKeyKeeperProcesses.compactMap(\.scriptPath).first {
            let normalized = normalizedPath(script)
            let hash = sha256Hex(normalized)
            return CallerSubject(
                kind: .script,
                fingerprint: "script:sha256=\(hash)",
                displayName: URL(fileURLWithPath: normalized).lastPathComponent,
                detail: normalized
            )
        }

        if let executable = nonKeyKeeperProcesses.compactMap(\.executablePath).first {
            let normalized = normalizedPath(executable)
            let hash = sha256Hex(normalized)
            return CallerSubject(
                kind: .executable,
                fingerprint: "executable:sha256=\(hash)",
                displayName: URL(fileURLWithPath: normalized).lastPathComponent,
                detail: normalized
            )
        }

        let fallback = "pid:\(peerPID)"
        return CallerSubject(
            kind: .executable,
            fingerprint: "executable:pid=\(peerPID)",
            displayName: fallback,
            detail: fallback
        )
    }

    public static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func processChain(startingAt pid: Int32, maxDepth: Int) -> [CallerProcess] {
        var result: [CallerProcess] = []
        var currentPID = pid
        var seen = Set<Int32>()

        for _ in 0..<maxDepth {
            guard currentPID > 0, !seen.contains(currentPID) else { break }
            seen.insert(currentPID)
            guard let process = processInfo(pid: currentPID) else { break }
            result.append(process)
            if process.parentPID <= 0 || process.parentPID == currentPID { break }
            currentPID = process.parentPID
        }

        return result
    }

    private static func processInfo(pid: Int32) -> CallerProcess? {
        let executablePath = executablePath(pid: pid)
        let parentPID = parentPID(pid: pid)
        let signature = executablePath.flatMap { codeSignatureInfo(path: $0) }
        let bundleIdentifier = executablePath.flatMap { appBundleIdentifier(executablePath: $0) }
        let scriptPath = scriptPath(pid: pid, executablePath: executablePath)

        return CallerProcess(
            pid: pid,
            parentPID: parentPID,
            executablePath: executablePath,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: signature?.teamIdentifier,
            signingIdentifier: signature?.signingIdentifier,
            scriptPath: scriptPath
        )
    }

    private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parentPID(pid: Int32) -> Int32 {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard result == size else { return 0 }
        return Int32(info.pbi_ppid)
    }

    private static func scriptPath(pid: Int32, executablePath: String?) -> String? {
        guard let executablePath,
              ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/env"].contains(executablePath),
              let args = arguments(pid: pid),
              args.count >= 2 else {
            return nil
        }

        let candidates = args.dropFirst().filter { !$0.hasPrefix("-") }
        return candidates.first { candidate in
            candidate.hasPrefix("/") && FileManager.default.fileExists(atPath: candidate)
        }
    }

    private static func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: Int32.self)
        }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        while index < size, args.count < Int(argc) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            if index > start {
                let data = Data(buffer[start..<index])
                if let arg = String(data: data, encoding: .utf8) {
                    args.append(arg)
                }
            }
            while index < size, buffer[index] == 0 { index += 1 }
        }

        return args
    }

    private struct SignatureInfo {
        var teamIdentifier: String?
        var signingIdentifier: String?
    }

    /// Signatures that chain to Apple: Developer ID, App Store, Apple Development, Apple's own.
    ///
    /// 【独立审计 2026-09-13】the connection's peer was checked for an intact signature only, and the
    /// processes upstream of the CLI were not checked at all — their team identifier was read
    /// straight out of the signature. A self-signed certificate can name any team.
    nonisolated(unsafe) static let appleAnchoredRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }()

    public static func isAppleAnchored(path: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        return isAppleAnchored(staticCode)
    }

    /// Resources are not re-validated: this runs for every process in the chain on every request,
    /// and a large app bundle takes seconds. The executable's own signature and chain are checked.
    private static func isAppleAnchored(_ staticCode: SecStaticCode) -> Bool {
        guard let requirement = appleAnchoredRequirement else { return false }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSDoNotValidateResources),
                                          requirement) == errSecSuccess
    }

    private static func codeSignatureInfo(path: String) -> SignatureInfo? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else { return nil }
        // An identity that does not chain to Apple names nobody: report it as unsigned.
        guard isAppleAnchored(staticCode) else { return SignatureInfo(teamIdentifier: nil, signingIdentifier: nil) }

        var info: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard copyStatus == errSecSuccess,
              let dict = info as? [String: Any] else {
            return nil
        }

        return SignatureInfo(
            teamIdentifier: dict[kSecCodeInfoTeamIdentifier as String] as? String,
            signingIdentifier: dict[kSecCodeInfoIdentifier as String] as? String
        )
    }

    private static func appBundleIdentifier(executablePath: String) -> String? {
        let url = URL(fileURLWithPath: executablePath)
        let components = url.pathComponents
        guard let appIndex = components.lastIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        let appPath = NSString.path(withComponents: Array(components[0...appIndex]))
        return Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
