import Foundation
import XCTest

final class UpdatePackagingContractTests: XCTestCase {
    func test签名接线拒绝误复制及伪造旧格式() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", repositoryRoot.appendingPathComponent("scripts/test-sparkle-key.py").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, output)
    }

    private let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testBrowserNativeHostAndExtensionAreBundledWithoutASeparateUnsignedBinary() throws {
        let script = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("Contents/Resources/browser-extension"))
        XCTAssertTrue(script.contains("Contents/Resources/browser-native-host"))
        let launcher = try String(contentsOf: repositoryRoot.appendingPathComponent("Resources/browser-native-host"), encoding: .utf8)
        XCTAssertTrue(launcher.contains("../MacOS/keykeeper"))
        XCTAssertTrue(launcher.contains("browser-native-host"))
        XCTAssertFalse(launcher.contains("eval "))
    }

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
        // Sparkle 2 signs the feed as a trailing `<!-- sparkle-signatures: ... -->` comment and
        // never writes a `sparkle:signature=` attribute, so checking for that attribute is a
        // guard that can only fire on a correctly signed feed — after the build and notarisation
        // have already been paid for.
        XCTAssertTrue(prepare.contains("sparkle-signatures:"))
        XCTAssertFalse(
            prepare.contains("sparkle:signature="),
            "Sparkle 2 never emits sparkle:signature=; checking for it rejects every valid feed"
        )
        // generate_appcast resolves a relative -o against the working directory, which is not the
        // directory the guards below read. Write it where it is checked, and where it is copied from.
        XCTAssertTrue(
            prepare.contains("-o \"$UPDATE_DIRECTORY/appcast.xml\""),
            "the generated appcast must land in the directory the guards verify"
        )

        let publish = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/publish-update.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(publish.contains("--confirm-version"))
        XCTAssertTrue(publish.contains("gh release create"))
        XCTAssertTrue(publish.contains("git -C \"$PROJECT_DIR\" commit"))
        // The feed lives on main (SUFeedURL points at raw.githubusercontent.com/.../main/appcast.xml),
        // so a publish that commits the appcast without pushing leaves every installed app on the
        // old version while reporting success.
        XCTAssertTrue(
            publish.contains("push origin main"),
            "the appcast commit must reach the branch the update feed is served from"
        )
        // The DMG on disk can be a later local rebuild that no longer matches the signed feed.
        XCTAssertTrue(publish.contains("stat -f%z"))
        XCTAssertTrue(
            publish.contains("length=\\\"$DMG_BYTES\\\""),
            "the uploaded DMG must be the one the appcast signed"
        )
    }

    /// 签名私钥可以本地自证身份：由私钥推导公钥，和 App 里内置的 SUPublicEDKey 比对。
    /// 这条链路必须自己先自检——一个推导不出来的机器如果直接报「不匹配」，人会以为钥匙错了。
    func test公钥比对脚本可以自检且从不打印私钥() throws {
        let script = repositoryRoot.appendingPathComponent("scripts/verify-sparkle-key.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--self-test"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("derivation works"), output)

        let source = try String(contentsOf: script, encoding: .utf8)
        XCTAssertFalse(source.contains("set -x"), "跟踪模式会把私钥打进日志")
        XCTAssertFalse(source.contains("echo \"$secret"), "私钥永远不打印")
        XCTAssertTrue(source.contains("sign_update --verify"), "要写明 sign_update --verify 不是这个检查")
    }
}
