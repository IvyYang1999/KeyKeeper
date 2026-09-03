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

    func test清空判定只看changeCount() {
        XCTAssertTrue(SecretPasteboard.shouldClear(currentChangeCount: 7, expectedChangeCount: 7))
        XCTAssertFalse(SecretPasteboard.shouldClear(currentChangeCount: 8, expectedChangeCount: 7))
    }
}
