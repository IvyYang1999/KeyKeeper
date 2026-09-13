import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// yyt 2026-09-13：「这个一定要走浏览器扩展吗……至少能不能给个跳转的链接」。
/// 扩展没上架 Chrome 应用商店，是随 App 一起装的一个文件夹；原来界面上对此只字不提，
/// 只说「从 KeyKeeper 扩展请求导入」，而用户根本没有拿到扩展的途径。
final class BrowserExtensionSetupTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ext-setup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func setup(withExtension: Bool = true) throws -> BrowserExtensionSetup {
        let folder = root.appendingPathComponent("browser-extension")
        let launcher = root.appendingPathComponent("browser-native-host")
        if withExtension {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: launcher)
        }
        return BrowserExtensionSetup(extensionFolder: folder, launcher: launcher,
                                     manifestURL: root.appendingPathComponent("host.json"),
                                     expectedExtensionID: String(repeating: "b", count: 32))
    }

    func test没带扩展的构建要如实说不是让人去装() throws {
        let setup = try setup(withExtension: false)
        XCTAssertEqual(setup.connection, .missingFromApp)
    }

    func test带了扩展但还没连上Chrome() throws {
        XCTAssertEqual(try setup().connection, .notRegistered)
    }

    func test连上之后能把扩展ID读回来() throws {
        let setup = try setup()
        let id = String(repeating: "b", count: 32)
        try setup.connect(extensionID: id)
        XCTAssertEqual(setup.connection, .registered(id))
        XCTAssertNoThrow(try setup.connect(extensionID: id), "重复连接同一个扩展不该报错")
    }

    /// 连接是 create-only：已经连着别的扩展时绝不悄悄改写——那等于把另一个扩展的
    /// 通道换成我们的。
    func test已经连着别的扩展时拒绝改写() throws {
        let setup = try setup()
        try setup.connect(extensionID: String(repeating: "b", count: 32))
        XCTAssertThrowsError(try setup.connect(extensionID: String(repeating: "c", count: 32))) {
            XCTAssertEqual($0 as? BrowserHostRegistrationError, .differentHostRegistered)
        }
    }

    /// 装好的扩展 ID 是常量（manifest 里钉死了 key），所以连接不需要任何输入。
    func test不用粘贴也能连上() throws {
        let setup = try setup()
        try setup.connect()
        XCTAssertEqual(setup.connection, .registered(String(repeating: "b", count: 32)))
    }

    /// 【诚实】这个文件是 KeyKeeper 自己写的，Chrome 从不回写。所以状态叫「已登记」，
    /// 不叫「已连接」，而且必须永远留一条改连别的扩展的出路——否则用户只能手删 JSON。
    func test已登记之后仍然可以改连别的扩展() throws {
        let setup = try setup()
        try setup.connect(extensionID: String(repeating: "b", count: 32))
        XCTAssertThrowsError(try setup.connect(extensionID: String(repeating: "c", count: 32)))
        try setup.connect(extensionID: String(repeating: "c", count: 32), replacingExisting: true)
        XCTAssertEqual(setup.connection, .registered(String(repeating: "c", count: 32)))
    }

    func test扩展ID必须是Chrome那种32位() throws {
        let setup = try setup()
        for bad in ["", "abc", String(repeating: "z", count: 32), String(repeating: "b", count: 31)] {
            XCTAssertThrowsError(try setup.connect(extensionID: bad), bad)
        }
        // 从 chrome://extensions 复制经常会带上空白
        XCTAssertNoThrow(try setup.connect(extensionID: "  " + String(repeating: "b", count: 32) + "\n"))
    }
}
