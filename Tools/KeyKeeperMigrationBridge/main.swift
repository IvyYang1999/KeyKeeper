import Foundation
import AppKit
import Darwin
import KeyKeeperCore

// No command takes a source path, Keychain service, value, or destination argument.
// This helper never saves/deletes items and never participates in cloud synchronization.
signal(SIGPIPE, SIG_IGN)
do {
    guard CommandLine.arguments.count == 1 else { throw IdentityMigrationError.identity }
    try IdentityMigrationSignature.current(.legacy)
    try IdentityMigrationSignature.parent()
    var outputInfo = stat()
    guard fstat(STDOUT_FILENO, &outputInfo) == 0, outputInfo.st_mode & S_IFMT == S_IFIFO else {
        throw IdentityMigrationError.identity
    }
    let fixture = try IdentityMigrationFixture.resolve(environment: ProcessInfo.processInfo.environment)
    // An isolated signed probe owns a different source and endpoint. The installed old App
    // may keep running; only a production capture requires that App to have quit.
    if fixture == nil {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: StorageIdentity.legacy.rawValue)
            .allSatisfy({ $0.processIdentifier == getpid() }) else { throw IdentityMigrationError.legacyRunning }
    }
    let endpoint = try LegacyEndpointLease(fixture: fixture)
    defer { withExtendedLifetime(endpoint) {} }
    let source = try IdentityMigrationLegacyCapture.capture(fixture: fixture)
    try IdentityMigrationSignature.parent()
    try IdentityMigrationPipe.write(source.encoded(), fd: STDOUT_FILENO, seconds: 20)
} catch {
    // A numeric fixed category is sufficient. Never forward native errors or source contents.
    exit((error as? IdentityMigrationError)?.exitCode ?? IdentityMigrationError.unavailable.exitCode)
}
