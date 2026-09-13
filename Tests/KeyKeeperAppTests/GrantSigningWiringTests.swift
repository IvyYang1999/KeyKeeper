import XCTest

/// 签名只有 App 能做：App 必须在碰授权文件之前配置好，命令行的撤销必须交给 App。
final class GrantSigningWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testApp先配置签名再清理授权() throws {
        let app = try source("Sources/KeyKeeperApp/AppDelegate.swift")
        let configure = try XCTUnwrap(app.range(of: "GrantFileIntegrity.processDefault ="))
        let prune = try XCTUnwrap(app.range(of: "GrantStore.default.pruneExpired()"))
        XCTAssertLessThan(configure.lowerBound, prune.lowerBound)
    }

    func test命令行撤销交给App() throws {
        let grants = try source("Sources/KeyKeeperCLI/GrantsCommand.swift")
        XCTAssertFalse(grants.contains(".revokeGrant("), "命令行直接写会让 App 不再信任整个文件")
        XCTAssertTrue(grants.contains("IPCClient.revokeServiceGrant"))
    }
}
