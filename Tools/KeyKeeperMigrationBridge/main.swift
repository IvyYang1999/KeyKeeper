import Foundation
import AppKit
import Darwin
import KeyKeeperCore

// The old-identity XPC service bundled at Contents/XPCServices/KeyKeeperMigrationBridge.xpc.
// It is signed as the earlier KeyKeeper so it can read the old Keychain items without a prompt,
// and therefore answers only the new App: the listener requires the new identity's signature,
// which XPC checks against each message's audit token (see IdentityMigrationBridgeService).
// No request takes a source path, Keychain service, value or destination. It never writes vault
// items or metadata and never takes part in cloud synchronization.

final class LegacySourceService: NSObject, IdentityMigrationBridgeService {
    static let shared = LegacySourceService()
    private let lock = NSLock()

    func captureLegacySource(fixture: Data?, reply: @escaping (Data?, Int32) -> Void) {
        do {
            let data = try serialized { try withLegacyAccess(fixture) {
                try IdentityMigrationLegacyCapture.capture(fixture: $0).encoded()
            } }
            reply(data, 0)
        } catch {
            // A fixed numeric category only. Never forward native errors or source contents.
            reply(nil, Self.code(error))
        }
    }

    private func serialized<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func withLegacyAccess<T>(_ fixtureData: Data?, _ body: (IdentityMigrationFixture?) throws -> T) throws -> T {
        let fixture = try IdentityMigrationBridge.decodeFixture(fixtureData)
        // An isolated signed probe owns a different source and endpoint. The installed old App
        // may keep running; only real sources require that App to have quit.
        if fixture == nil {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: StorageIdentity.legacy.rawValue)
                .allSatisfy({ $0.processIdentifier == getpid() }) else { throw IdentityMigrationError.legacyRunning }
        }
        let endpoint = try LegacyEndpointLease(fixture: fixture)
        defer { withExtendedLifetime(endpoint) {} }
        return try body(fixture)
    }

    private static func code(_ error: Error) -> Int32 {
        (error as? IdentityMigrationError)?.exitCode ?? IdentityMigrationError.unavailable.exitCode
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only the new App may use this connection. XPC checks every message against the audit
        // token stamped when it was sent, and invalidates the connection on the first mismatch.
        // 【曾经的 bug】set on the listener instead: a service listener does not support that and
        // the service crashed at launch (SDK NSXPCConnection.h: anonymous or Mach-service only).
        connection.setCodeSigningRequirement(IdentityMigrationSignature.requirementString(.current))
        connection.exportedInterface = NSXPCInterface(with: IdentityMigrationBridgeService.self)
        connection.exportedObject = LegacySourceService.shared
        connection.resume()
        return true
    }
}

signal(SIGPIPE, SIG_IGN)
do { try IdentityMigrationSignature.current(.legacy) } catch {
    exit(IdentityMigrationError.identity.exitCode)
}
let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
