import XCTest
@testable import KeyKeeperCore

/// 【独立审计 2026-09-13】签名检查只问「签名坏没坏」，不问「是谁签的」：自签证书可以在证书里写上任意
/// 团队 ID，签出一个「签名完好」的程序，冒充某个已被授权的 app。CLI 上游的进程更是连签名坏没坏都没查，
/// 团队 ID 直接从签名信息里读。能算数的团队 ID，必须来自苹果签发的证书链。
final class SignatureAnchorTests: XCTestCase {
    func test苹果签发的程序算数() {
        XCTAssertTrue(CallerIdentityResolver.isAppleAnchored(path: "/usr/bin/true"))
    }

    func test自己签的程序不算数() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anchor-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("true")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: copy.path)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", copy.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        XCTAssertFalse(CallerIdentityResolver.isAppleAnchored(path: copy.path))
    }
}
