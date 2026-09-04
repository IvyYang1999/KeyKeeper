import XCTest
@testable import KeyKeeperApp

@MainActor
final class UpdateControllerTests: XCTestCase {
    func test初始化只读取Sparkle偏好而不覆盖用户选择() {
        let driver = UpdateDriverSpy(
            canCheckForUpdates: true,
            automaticallyDownloadsUpdates: false
        )

        let controller = UpdateController(driver: driver)

        XCTAssertTrue(controller.canCheckForUpdates)
        XCTAssertFalse(controller.automaticallyInstallsUpdates)
        XCTAssertEqual(driver.automaticPreferenceWrites, [])
    }

    func test关闭自动安装仍保留后台检查和更新提示能力() {
        let driver = UpdateDriverSpy(
            canCheckForUpdates: true,
            automaticallyDownloadsUpdates: true
        )
        let controller = UpdateController(driver: driver)

        controller.setAutomaticallyInstallsUpdates(false)

        XCTAssertEqual(driver.automaticPreferenceWrites, [false])
        XCTAssertTrue(driver.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.automaticallyInstallsUpdates)
    }

    func test手动检查只在Sparkle允许时触发() {
        let blockedDriver = UpdateDriverSpy(canCheckForUpdates: false)
        let blockedController = UpdateController(driver: blockedDriver)
        blockedController.checkForUpdates()
        XCTAssertEqual(blockedDriver.checkCount, 0)

        let readyDriver = UpdateDriverSpy(canCheckForUpdates: true)
        let readyController = UpdateController(driver: readyDriver)
        readyController.checkForUpdates()
        XCTAssertEqual(readyDriver.checkCount, 1)
    }

    func test配置缺少Feed或公钥时禁用更新器() {
        XCTAssertFalse(UpdateConfiguration(feedURL: nil, publicEDKey: nil).isUsable)
        XCTAssertFalse(UpdateConfiguration(
            feedURL: URL(string: "https://example.com/appcast.xml"),
            publicEDKey: nil
        ).isUsable)
        XCTAssertFalse(UpdateConfiguration(
            feedURL: URL(string: "http://example.com/appcast.xml"),
            publicEDKey: "public-key"
        ).isUsable)
        XCTAssertTrue(UpdateConfiguration(
            feedURL: URL(string: "https://example.com/appcast.xml"),
            publicEDKey: "public-key"
        ).isUsable)
    }
}

@MainActor
private final class UpdateDriverSpy: UpdateDriving {
    var canCheckForUpdates: Bool
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates: Bool {
        didSet { automaticPreferenceWrites.append(automaticallyDownloadsUpdates) }
    }
    var stateDidChange: ((UpdateDriverState) -> Void)?

    private(set) var automaticPreferenceWrites: [Bool] = []
    private(set) var checkCount = 0

    init(
        canCheckForUpdates: Bool,
        automaticallyDownloadsUpdates: Bool = false
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        checkCount += 1
    }
}
