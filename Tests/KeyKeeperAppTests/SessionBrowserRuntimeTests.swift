import XCTest
import AppKit
import WebKit
import Security
import Darwin
import KeyKeeperCore
@testable import KeyKeeperApp

@MainActor final class SessionBrowserRuntimeTests: XCTestCase {
    func testSyntheticHTTPSAuthenticationOutsideOriginBlockAndEphemeralCleanup() async throws {
        guard ProcessInfo.processInfo.environment["KEYKEEPER_BROWSER_E2E"] == "1" else {
            throw XCTSkip("Run KEYKEEPER_BROWSER_E2E=1 for the local synthetic HTTPS fixture.")
        }
        _ = NSApplication.shared
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("keykeeper-https-fixture-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let openssl = Process(); openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
                             "-keyout", dir.appendingPathComponent("fixture-key.pem").path,
                             "-out", dir.appendingPathComponent("fixture-cert.pem").path]
        openssl.standardOutput = FileHandle.nullDevice; openssl.standardError = FileHandle.nullDevice
        try openssl.run(); openssl.waitUntilExit(); XCTAssertEqual(openssl.terminationStatus, 0)
        let pem = try String(contentsOf: dir.appendingPathComponent("fixture-cert.pem"), encoding: .utf8)
        let certificateBytes = try XCTUnwrap(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("---") }.joined()))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = Process(); let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["node", root.appendingPathComponent("tests-browser/https-fixture.cjs").path, dir.path]
        server.standardOutput = output; server.standardError = FileHandle.nullDevice
        try server.run(); defer { server.terminate(); server.waitUntilExit() }
        var ready = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 5000) > 0 else { throw NSError(domain: "SyntheticFixture", code: 1) }
        let port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let origin = "https://localhost:\(port)"
        let runtime = SessionBrowserRuntime(trustEvaluator: { space in
            guard space.host == "localhost", space.port == port, let trust = space.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return false }
            return SecCertificateCopyData(leaf) as Data == certificateBytes
        })
        defer { runtime.stopAll() }
        let input = BrowserSessionImport(id: UUID().uuidString, origin: origin, label: "Synthetic HTTPS", cookies: [
            .init(name: "fixture", value: "synthetic", domain: "localhost", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
        let completion = expectation(description: "opens after verified Cookie install")
        runtime.open(input) { XCTAssertTrue($0); completion.fulfill() }
        await fulfillment(of: [completion], timeout: 20)
        let web = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView as? WKWebView }.first(where: { $0.url?.absoluteString.hasPrefix(origin) ?? false }))
        var state = ""
        for _ in 0..<50 {
            state = (try? await web.evaluateJavaScript("document.getElementById('state')?.textContent")) as? String ?? ""
            if state == "AUTHENTICATED" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(state, "AUTHENTICATED")
        let scriptCookies = try await web.evaluateJavaScript("document.cookie") as? String
        XCTAssertEqual(scriptCookies, "", "HttpOnly remains inaccessible to page JS")
        _ = try await web.evaluateJavaScript("document.getElementById('outside').click()")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(web.url?.host, "localhost")
        let count = try await web.callAsyncJavaScript("return await (await fetch('/counts')).text()", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(count as? String, "0", "Outside-origin image and navigation must not reach the fixture")
        runtime.stopAll()
        for _ in 0..<50 {
            if await web.configuration.websiteDataStore.httpCookieStore.allCookies().isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let remaining = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testRealWebKitCookieRoundTripBeforeNavigationAndStopReleasesWindow() async throws {
        // Opt-in desktop test. Synthetic localhost Cookie only; no real website/account.
        guard ProcessInfo.processInfo.environment["KEYKEEPER_BROWSER_E2E"] == "1" else {
            throw XCTSkip("Requires a local desktop WebKit process; run KEYKEEPER_BROWSER_E2E=1.")
        }
        _ = NSApplication.shared
        let runtime = SessionBrowserRuntime()
        let input = BrowserSessionImport(id: UUID().uuidString, origin: "https://localhost:49671", label: "Synthetic WebKit", cookies: [
            .init(name: "fixture", value: "synthetic", domain: "localhost", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
        defer { runtime.stopAll() }
        let completed = expectation(description: "bounded real WebKit open")
        var opened = false
        runtime.open(input) { opened = $0; completed.fulfill() }
        await fulfillment(of: [completed], timeout: 20)
        XCTAssertTrue(opened, "Actual WebKit must preserve all supported Cookie flags before marking a window opened")
        XCTAssertEqual(runtime.activeIDs, [input.id])
        let web = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView as? WKWebView }.first)
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
        runtime.stop(id: input.id)
        XCTAssertTrue(runtime.activeIDs.isEmpty)
        XCTAssertNil(web.superview)
    }
}
