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
}

public enum CallerIdentityResolver {
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

    private static func codeSignatureInfo(path: String) -> SignatureInfo? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else { return nil }

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
