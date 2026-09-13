import AppKit
import XCTest
@testable import KeyKeeperApp

final class SecretPasteboardTests: XCTestCase {
    func test写入带隐藏标记且到期清空() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let changeCount = SecretPasteboard.write("opaque-secret", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "opaque-secret")
        XCTAssertTrue(pasteboard.types?.contains(SecretPasteboard.concealedType) ?? false)
        XCTAssertTrue(SecretPasteboard.clearIfUnchanged(since: changeCount, pasteboard: pasteboard))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func test用户随后复制了别的内容则不清空() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let changeCount = SecretPasteboard.write("opaque-secret", to: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)

        XCTAssertFalse(SecretPasteboard.clearIfUnchanged(since: changeCount, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "something else")
    }

    /// 【安全】general 剪贴板默认参与「通用剪贴板」：在 App 里点一次复制，密钥就会跟着
    /// 飘到同一 Apple ID 下的 iPhone / iPad 上去。`.currentHostOnly` 是唯一能关掉它的公开
    /// 开关，而且只能在写入时声明。这件事在进程内观察不到，所以直接盯源码。
    func test密钥只写到本机不跟着同步到别的设备() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/SecretPasteboard.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("prepareForNewContents(with: .currentHostOnly)"),
                      "写密钥必须用 prepareForNewContents(with: .currentHostOnly)，clearContents() 会让它上通用剪贴板")
        XCTAssertFalse(source.contains("pasteboard.clearContents()\n        pasteboard.declareTypes"),
                       "旧的 clearContents + declareTypes 组合等于默认允许跨设备同步")
    }

    func test清空判定只看changeCount() {
        XCTAssertTrue(SecretPasteboard.shouldClear(currentChangeCount: 7, expectedChangeCount: 7))
        XCTAssertFalse(SecretPasteboard.shouldClear(currentChangeCount: 8, expectedChangeCount: 7))
    }
}
