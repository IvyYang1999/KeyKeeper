import AppKit
import KeyKeeperCore

/// Presentation only; never used as an authorization identity.
struct AuthorizationCallerPresentation {
    let kind: CallerSubject.Kind
    let rawName: String
    let bundleIdentifier: String?
    let appPath: String?

    init(_ caller: CallerIdentity) {
        kind = caller.subject.kind
        rawName = caller.subject.displayName
        // Peer fields describe our CLI on a relayed request, not the subject being approved.
        // Only borrow a process path when the stored chain reconstructs that same subject.
        let selected = CallerIdentityResolver.selectSubject(from: caller.parentChain, peerPID: caller.peerPID)
        let chainMatches = selected == caller.subject
            || CallerIdentityResolver.courierUpstream(selected) == caller.subject
        let process = chainMatches ? CallerIdentityResolver.subjectProcess(from: caller.parentChain) : nil
        let directApp = !caller.subject.fingerprint.hasPrefix(CallerSubject.relayedPrefix)
            && kind == .app && rawName == caller.bundleIdentifier
            && caller.subject.detail == caller.executablePath
        let executable = process?.executablePath ?? (directApp ? caller.executablePath : nil)
        appPath = kind == .app ? executable.flatMap(Self.appBundlePath) : nil
        switch kind {
        case .app: bundleIdentifier = rawName
        case .executable: bundleIdentifier = CallerAppIcon.desktopApps[rawName] == nil ? nil : rawName
        case .script: bundleIdentifier = nil
        }
    }

    func name(displayName: (String) -> String = { FileManager.default.displayName(atPath: $0) }) -> String {
        if let bundleIdentifier, let known = CallerAppIcon.friendlyNames[bundleIdentifier] { return known }
        if let appPath {
            let shown = displayName(appPath).replacingOccurrences(of: ".app", with: "")
            let line = CallerStatedReason.printableLine(shown, limit: 60)
            if !line.isEmpty { return line }
        }
        return TrustPromptModel.sanitizedCaller(rawName)
    }

    func image(pathIcon: (String) -> NSImage? = {
        FileManager.default.fileExists(atPath: $0) ? NSWorkspace.shared.icon(forFile: $0) : nil
    }, bundleIcon: (String) -> NSImage? = { CallerAppIcon.image(for: $0) }) -> NSImage? {
        if let appPath, let icon = pathIcon(appPath) { return icon }
        return bundleIdentifier.flatMap(bundleIcon)
    }

    private static func appBundlePath(_ executable: String) -> String? {
        let components = URL(fileURLWithPath: executable).pathComponents
        guard let index = components.lastIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[0...index]))
    }
}
