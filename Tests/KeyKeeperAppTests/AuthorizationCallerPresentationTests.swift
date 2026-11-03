import AppKit
import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

final class AuthorizationCallerPresentationTests: XCTestCase {
    static func courier(bundle: String = "com.openai.codex", app: String = "Codex") -> CallerIdentity {
        let cli = CallerProcess(pid: 42, parentPID: 43,
            executablePath: "/Applications/KeyKeeper.app/Contents/MacOS/keykeeper",
            bundleIdentifier: "dev.keykeeper.app", teamIdentifier: "SYNTHETIC")
        let upstream = CallerProcess(pid: 43, parentPID: 1,
            executablePath: "/Applications/\(app).app/Contents/MacOS/\(app)",
            bundleIdentifier: bundle, teamIdentifier: "SYNTHETIC")
        let chain = [cli, upstream]
        return CallerIdentity(peerPID: cli.pid, executablePath: cli.executablePath,
            bundleIdentifier: cli.bundleIdentifier, parentChain: chain,
            subject: CallerIdentityResolver.courierUpstream(CallerIdentityResolver.selectSubject(from: chain, peerPID: cli.pid)))
    }

    func testCourierUsesCodexSubjectForBothNameAndIcon() {
        let caller = Self.courier()
        let original = caller
        let presentation = AuthorizationCallerPresentation(caller)
        XCTAssertEqual(presentation.name(), "Codex")
        XCTAssertEqual(presentation.bundleIdentifier, "com.openai.codex")
        XCTAssertEqual(presentation.appPath, "/Applications/Codex.app")
        let codex = NSImage(size: NSSize(width: 8, height: 8))
        XCTAssertTrue(presentation.image(pathIcon: { $0 == "/Applications/Codex.app" ? codex : nil }, bundleIcon: { _ in nil }) === codex)
        XCTAssertEqual(caller, original)
    }

    func testMissingIconCannotFallBackToCourier() {
        let presentation = AuthorizationCallerPresentation(Self.courier())
        var lookups: [String] = []
        XCTAssertNil(presentation.image(pathIcon: { lookups.append($0); return nil }, bundleIcon: { lookups.append($0); return nil }))
        XCTAssertFalse(lookups.contains(where: { $0.localizedCaseInsensitiveContains("keykeeper") }))
    }

    func testUnknownUpstreamUsesItsOwnPathAndName() {
        let presentation = AuthorizationCallerPresentation(Self.courier(bundle: "test.other", app: "Other"))
        XCTAssertEqual(presentation.appPath, "/Applications/Other.app")
        XCTAssertEqual(presentation.name(displayName: { $0 == "/Applications/Other.app" ? "Other.app" : "WRONG.app" }), "Other")
    }

    func testMissingOrMismatchedChainCannotBorrowPeerPath() {
        for mismatched in [false, true] {
            var caller = Self.courier()
            caller.parentChain = mismatched ? Self.courier(bundle: "test.other", app: "Other").parentChain : []
            let presentation = AuthorizationCallerPresentation(caller)
            XCTAssertNil(presentation.appPath)
            XCTAssertEqual(presentation.name(), "Codex")
            XCTAssertEqual(presentation.bundleIdentifier, "com.openai.codex")
        }
    }

    func testDirectAppPathAndNonAppKinds() {
        let path = "/Applications/Other.app/Contents/MacOS/Other"
        let direct = CallerIdentity(peerPID: 42, executablePath: path, bundleIdentifier: "test.other",
            subject: .init(kind: .app, fingerprint: "app:direct", displayName: "test.other", detail: path))
        XCTAssertEqual(AuthorizationCallerPresentation(direct).appPath, "/Applications/Other.app")
        for kind: CallerSubject.Kind in [.script, .executable] {
            let caller = CallerIdentity(peerPID: 42, executablePath: path, bundleIdentifier: "test.other",
                subject: .init(kind: kind, fingerprint: "unverified:fixture", displayName: "worker", detail: ""))
            let presentation = AuthorizationCallerPresentation(caller)
            XCTAssertEqual(presentation.kind, kind)
            XCTAssertEqual(presentation.name(), "worker")
            XCTAssertNil(presentation.appPath)
            XCTAssertNil(presentation.bundleIdentifier)
        }
    }

    func testOnlyExactKnownCLINameUsesDesktopAlias() {
        for raw in ["com.openai.codex.cli", "unrelated:com.openai.codex.cli"] {
            let caller = CallerIdentity(peerPID: 42,
                subject: .init(kind: .executable, fingerprint: "unverified:fixture", displayName: raw, detail: ""))
            let presentation = AuthorizationCallerPresentation(caller)
            XCTAssertEqual(presentation.bundleIdentifier, raw == "com.openai.codex.cli" ? raw : nil)
            XCTAssertEqual(presentation.name(), raw == "com.openai.codex.cli" ? "Codex" : raw)
        }
    }
}
