import XCTest
@testable import KeyKeeperCore

private final class KeyIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    func readBlob() throws -> Data? { blob }
    func writeBlob(_ data: Data, replacingExisting: Bool) throws { blob = data }
}

/// 【独立审计 2026-09-13 · 早就存在的 high】授权文件是普通文件，以用户身份运行的任何程序都能写。
/// 往里追加一条给自己的「始终允许」，或者把模式改成宽松，就能不弹窗读走 strict 凭据。
final class GrantFileIntegrityTests: XCTestCase {
    private var dir: URL!
    private var io: KeyIO!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grant-integrity-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        io = KeyIO()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// 照着文件原来的格式改：解码、改一处、再编码写回。签名字段原封不动留着。
    private func forge<T: Codable>(_ type: T.Type, _ name: String, _ mutate: (inout T) -> Void) throws {
        let url = dir.appendingPathComponent(name)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var file = try decoder.decode(T.self, from: Data(contentsOf: url))
        mutate(&file)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url)
    }

    func test改过的授权文件里的授权一条都不认() throws {
        let store = GrantStore(directory: dir, integrity: GrantFileIntegrity(io: io))
        try store.addGrant(Grant(credentialId: "sparkle", duration: .always, subjectFingerprint: "unsigned:path=real"))
        XCTAssertNotNil(try store.findValidGrant(credentialId: "sparkle", sessionId: nil, fingerprint: "unsigned:path=real"))

        try forge(GrantFile.self, "grants.json") {
            $0.grants.append(Grant(credentialId: "sparkle", duration: .always, subjectFingerprint: "unsigned:path=evil"))
        }
        XCTAssertNil(try store.findValidGrant(credentialId: "sparkle", sessionId: nil, fingerprint: "unsigned:path=evil"))
        XCTAssertNil(try store.findValidGrant(credentialId: "sparkle", sessionId: nil, fingerprint: "unsigned:path=real"),
                     "认不出的文件，里面的授权一条都不作数")

        try forge(GrantFile.self, "grants.json") { $0.integrity = nil }
        XCTAssertNil(try store.findValidGrant(credentialId: "sparkle", sessionId: nil, fingerprint: "unsigned:path=evil"),
                     "删掉签名字段不能把检查关掉")
    }

    func testService授权文件改成宽松模式不作数() throws {
        let store = ServiceGrantStore(directory: dir, integrity: GrantFileIntegrity(io: io))
        try store.setAuthorizationMode(.enforced)
        try forge(ServiceGrantFile.self, "service-grants.json") {
            $0.mode = .permissive
            $0.grants.append(ServiceGrant(credentialId: "c", subjectFingerprint: "unsigned:path=evil",
                                          subjectDisplayName: "x", fields: ["f"], duration: .always))
        }
        XCTAssertEqual(try store.authorizationMode(), .enforced)
        XCTAssertNil(try store.findValidGrant(credentialId: "c", subjectFingerprint: "unsigned:path=evil", fieldName: "f"))
    }

    func test还没签过名的旧文件照常可用并在下次写入时签上() throws {
        try GrantStore(directory: dir).addGrant(Grant(credentialId: "c", duration: .always, subjectFingerprint: "unsigned:path=real"))
        let store = GrantStore(directory: dir, integrity: GrantFileIntegrity(io: io))
        XCTAssertNotNil(try store.findValidGrant(credentialId: "c", sessionId: nil, fingerprint: "unsigned:path=real"))
        try store.pruneExpired()
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("grants.json"), encoding: .utf8).contains("\"integrity\""))
        XCTAssertNotNil(try store.findValidGrant(credentialId: "c", sessionId: nil, fingerprint: "unsigned:path=real"))
    }

    func test命令行不能改App签过名的文件() throws {
        let app = ServiceGrantStore(directory: dir, integrity: GrantFileIntegrity(io: io))
        let grant = ServiceGrant(credentialId: "c", subjectFingerprint: "unsigned:path=real",
                                 subjectDisplayName: "x", fields: ["f"], duration: .always)
        try app.addGrant(grant)
        let url = dir.appendingPathComponent("service-grants.json")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ServiceGrantStore(directory: dir).revokeGrant(id: grant.id))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertNotNil(try app.findValidGrant(credentialId: "c", subjectFingerprint: "unsigned:path=real", fieldName: "f"))
    }

    func test撤销请求能收发() throws {
        let request = try JSONDecoder().decode(IPCRequest.self, from: JSONEncoder().encode(IPCRequest.serviceGrantRevoke(.init(id: "g1"))))
        guard case .serviceGrantRevoke(let decoded) = request else { return XCTFail("\(request)") }
        XCTAssertEqual(decoded.id, "g1")
        let response = try JSONDecoder().decode(IPCResponse.self, from: JSONEncoder().encode(IPCResponse.serviceGrantRevoke(.init(success: true))))
        guard case .serviceGrantRevoke(let answer) = response else { return XCTFail("\(response)") }
        XCTAssertTrue(answer.success)
    }
}
