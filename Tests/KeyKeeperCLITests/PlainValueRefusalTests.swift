import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

final class PlainValueRefusalTests: XCTestCase {
    /// 【独立审计第二轮】连不上 App、App 忙或太旧时，也报「元数据被外部改过」，把人引去查一个并不存在的改动。
    func test连不上和被改过说的是两回事() {
        XCTAssertFalse(PlainValueRefusal.message(for: nil).contains("changed outside"))
        XCTAssertTrue(PlainValueRefusal.message(for: .tampered).contains("changed outside"))
    }

    /// 【独立审计第二轮】命令行和 App 等批准一样久，永远是命令行先放弃，报「App 没响应」而不是真正的原因。
    func test命令行比App多等一会儿() throws {
        XCTAssertGreaterThan(IPCConstants.clientGrace, 0)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let client = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperCLI/IPCClient.swift"), encoding: .utf8)
        XCTAssertFalse(client.contains("Int(IPCConstants.authTimeout)"))
    }
}
