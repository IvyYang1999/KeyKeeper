import XCTest
@testable import KeyKeeperApp

/// 【安全审计 2026-09-13】Sparkle 的更新源地址可以被 user defaults 覆盖——同 UID 进程一句
/// `defaults write com.keykeeper.app SUFeedURL …` 就能把更新指到自己那儿。签名校验还在，
/// 所以装不进任意 App，但足够让「检查更新」永远回答「已是最新」，把人钉在一个有已知漏洞
/// 的版本上。
///
/// 修法是给 updater 一个 delegate，把编译进包里的那个地址钉死。
final class UpdateFeedPinningTests: XCTestCase {
    func test更新源地址来自包内而不是用户偏好() throws {
        let pinned = try XCTUnwrap(UpdateFeedPolicy.pinnedFeedURL(
            bundleInfo: ["SUFeedURL": "https://raw.githubusercontent.com/IvyYang1999/KeyKeeper/main/appcast.xml"]))
        XCTAssertEqual(pinned, "https://raw.githubusercontent.com/IvyYang1999/KeyKeeper/main/appcast.xml")
    }

    /// 包里没写或者写了个非 https 的，宁可不给地址（Sparkle 会退回它自己的解析），
    /// 也不能把一个不安全的地址钉死。
    func test非https或缺失一律不钉() {
        XCTAssertNil(UpdateFeedPolicy.pinnedFeedURL(bundleInfo: [:]))
        XCTAssertNil(UpdateFeedPolicy.pinnedFeedURL(bundleInfo: ["SUFeedURL": "http://example.com/appcast.xml"]))
        XCTAssertNil(UpdateFeedPolicy.pinnedFeedURL(bundleInfo: ["SUFeedURL": "not a url"]))
        XCTAssertNil(UpdateFeedPolicy.pinnedFeedURL(bundleInfo: ["SUFeedURL": 42]))
    }

    /// 装出来的 App 里那个地址必须是 https，否则钉死也没意义。
    func test生产包里的地址是https() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let feed = try XCTUnwrap(plist["SUFeedURL"] as? String)
        XCTAssertNotNil(UpdateFeedPolicy.pinnedFeedURL(bundleInfo: ["SUFeedURL": feed]))
    }
}
