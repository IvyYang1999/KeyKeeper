import XCTest
@testable import KeyKeeperCore

final class VaultRevisionWireTests: XCTestCase {
    private func revision() throws -> VaultRevision {
        .init(instanceID: UUID(), epoch: 1, metadataDigest: try VaultRevision.metadataDigest(for: MetaFile()))
    }

    func testBoundRequestsUseDistinctDiscriminatorAndCannotLoseRevision() throws {
        let token = try revision()
        let value = ValueRequest(credentialId: "synthetic", fieldName: "key", sessionId: nil, revision: token)
        let data = try JSONEncoder().encode(IPCRequest.value(value))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "revisionValue")
        guard case .value(let roundTrip) = try JSONDecoder().decode(IPCRequest.self, from: data) else { return XCTFail() }
        XCTAssertEqual(roundTrip.revision, token)
        object["type"] = "value"
        XCTAssertThrowsError(try JSONDecoder().decode(IPCRequest.self, from: JSONSerialization.data(withJSONObject: object)))
        object["type"] = "revisionValue"
        var payload = try XCTUnwrap(object["data"] as? [String: Any])
        payload.removeValue(forKey: "revision"); object["data"] = payload
        XCTAssertThrowsError(try JSONDecoder().decode(IPCRequest.self, from: JSONSerialization.data(withJSONObject: object)))

        let auth = AuthRequest(credentialId: "synthetic", credentialLabel: "Synthetic", fieldNames: ["key"],
            sessionId: nil, sessionLabel: nil, pid: 1, revision: token)
        let encodedAuth = try JSONEncoder().encode(IPCRequest.auth(auth))
        let authObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedAuth) as? [String: Any])
        XCTAssertEqual(authObject["type"] as? String, "revisionAuth")
    }

    func testSnapshotAndLegacyWireRemainDistinctAndDecodable() throws {
        let encoded = try JSONEncoder().encode(IPCRequest.vaultSnapshot(.init(inspectValues: true)))
        guard case .vaultSnapshot(let request) = try JSONDecoder().decode(IPCRequest.self, from: encoded) else {
            return XCTFail()
        }
        XCTAssertTrue(request.inspectValues)
        let legacy = IPCRequest.value(.init(credentialId: "synthetic", fieldName: "key", sessionId: nil))
        let bytes = try JSONEncoder().encode(legacy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "value")
        XCTAssertNoThrow(try JSONDecoder().decode(IPCRequest.self, from: bytes))
    }
}
