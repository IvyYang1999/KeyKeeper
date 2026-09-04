import Foundation
import XCTest

final class UpdatePackagingContractTests: XCTestCase {
    private let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func test版本只有一个权威来源且可供Sparkle比较() throws {
        let version = try String(
            contentsOf: repositoryRoot.appendingPathComponent("VERSION"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertNotNil(version.range(
            of: #"^\d+\.\d+\.\d+$"#,
            options: .regularExpression
        ))

        for relativePath in ["scripts/build-app.sh", "scripts/post-commit"] {
            let script = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertFalse(script.contains("VERSION=\"0."), "\(relativePath) must read VERSION")
        }
    }

    func test生产InfoPlist固定启用提示并默认关闭自动安装() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        let feedURL = try XCTUnwrap(URL(string: try XCTUnwrap(plist["SUFeedURL"] as? String)))
        XCTAssertEqual(feedURL.scheme, "https")
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, false)

        let publicKey = try XCTUnwrap(plist["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
    }

    func test打包脚本嵌入Sparkle且postCommit复用同一实现() throws {
        let buildScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(buildScript.contains("Contents/Frameworks/Sparkle.framework"))

        let postCommit = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/post-commit"),
            encoding: .utf8
        )
        XCTAssertTrue(postCommit.contains("build-app.sh\" --skip-dmg"))
        XCTAssertFalse(postCommit.contains("<key>CFBundleVersion</key>"))
    }

    func test发布流程先公证再签appcast且需要显式版本确认() throws {
        let prepare = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/prepare-update.sh"),
            encoding: .utf8
        )
        let notarizePosition = try XCTUnwrap(prepare.range(of: "notarize-update.sh"))
        let appcastPosition = try XCTUnwrap(prepare.range(of: "generate_appcast"))
        XCTAssertLessThan(notarizePosition.lowerBound, appcastPosition.lowerBound)
        XCTAssertTrue(prepare.contains("sparkle:edSignature="))
        XCTAssertTrue(prepare.contains("sparkle:signature="))

        let publish = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/publish-update.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(publish.contains("--confirm-version"))
        XCTAssertTrue(publish.contains("gh release create"))
        XCTAssertTrue(publish.contains("git -C \"$PROJECT_DIR\" commit"))
    }
}
