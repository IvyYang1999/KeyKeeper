import XCTest
@testable import KeyKeeperApp

final class AgentPluginSetupTests: XCTestCase {
    func testMissingPackageDoesNotOfferBrokenInstallCommands() {
        XCTAssertFalse(AgentPluginSetup(root: nil).isAvailable)
        XCTAssertNil(AgentPluginSetup(root: nil).commands(for: .codex))
        XCTAssertFalse(AgentPluginSetup(root: URL(fileURLWithPath: "/nonexistent")).isAvailable)
    }

    func testCommandsQuoteAppPathAndRequireSuccessfulMarketplaceAdd() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyKeeper's App \(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for relative in AgentPluginSetup.requiredFiles {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        let setup = AgentPluginSetup(root: root)
        XCTAssertTrue(setup.isAvailable)
        for host in AgentPluginSetup.Host.allCases {
            let command = try XCTUnwrap(setup.commands(for: host))
            XCTAssertTrue(command.contains("'\\''"))
            XCTAssertTrue(command.contains(" && "))
            XCTAssertFalse(command.contains("sudo"))
            XCTAssertTrue(command.contains("keykeeper@keykeeper-plugins"))
        }
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(setup.codexURL), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first?.value, root.appendingPathComponent(".agents/plugins/marketplace.json").path)
    }
}
