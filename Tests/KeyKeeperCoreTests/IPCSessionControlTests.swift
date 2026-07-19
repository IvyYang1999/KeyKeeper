import Foundation
import XCTest
@testable import KeyKeeperCore

final class IPCSessionControlTests: XCTestCase {
    func testLegacyRequestJSONRemainsUnchanged() throws {
        try assertJSONObject(
            IPCRequest.auth(AuthRequest(
                credentialId: "credential-a",
                credentialLabel: "Credential A",
                fieldNames: ["token"],
                sessionId: "session-a",
                sessionLabel: "Terminal",
                pid: 42
            )),
            equals: [
                "type": "auth",
                "data": [
                    "credentialId": "credential-a",
                    "credentialLabel": "Credential A",
                    "fieldNames": ["token"],
                    "sessionId": "session-a",
                    "sessionLabel": "Terminal",
                    "pid": 42,
                ],
            ]
        )
        try assertJSONObject(
            IPCRequest.value(ValueRequest(
                credentialId: "credential-a",
                fieldName: "token",
                sessionId: nil,
                requestedFieldNames: ["token"]
            )),
            equals: [
                "type": "value",
                "data": [
                    "credentialId": "credential-a",
                    "fieldName": "token",
                    "requestedFieldNames": ["token"],
                ],
            ]
        )
        try assertJSONObject(
            IPCRequest.serviceRequests(ServiceRequestsListRequest()),
            equals: ["type": "serviceRequests", "data": [:]]
        )
    }

    func testLegacyResponseJSONRemainsUnchanged() throws {
        try assertJSONObject(
            IPCResponse.auth(AuthResponse(granted: true, grantId: "grant-a")),
            equals: [
                "type": "auth",
                "data": ["granted": true, "grantId": "grant-a"],
            ]
        )
        try assertJSONObject(
            IPCResponse.value(ValueResponse(
                success: false,
                error: "not found",
                errorCode: .notFound
            )),
            equals: [
                "type": "value",
                "data": [
                    "success": false,
                    "error": "not found",
                    "errorCode": "notFound",
                ],
            ]
        )
        try assertJSONObject(
            IPCResponse.serviceRequests(ServiceRequestsListResponse(requests: [])),
            equals: [
                "type": "serviceRequests",
                "data": ["requests": []],
            ]
        )
    }

    func testValueResponseStorageErrorExtensionKeepsLegacyErrorCodeDecodable() throws {
        let response = IPCResponse.value(ValueResponse(
            success: false,
            error: "Credential vault is locked",
            errorCode: .keychainError,
            storageErrorCode: .vaultLocked
        ))
        let encoded = try JSONEncoder().encode(response)
        let legacy = try JSONDecoder().decode(LegacyIPCEnvelope.self, from: encoded)

        XCTAssertEqual(legacy.type, "value")
        XCTAssertFalse(legacy.data.success)
        XCTAssertEqual(legacy.data.errorCode, .keychainError)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["storageErrorCode"] as? String, "vaultLocked")
    }

    func testValueResponseWithoutStorageErrorKeepsLegacyJSONShape() throws {
        try assertJSONObject(
            IPCResponse.value(ValueResponse(
                success: false,
                error: "not found",
                errorCode: .notFound
            )),
            equals: [
                "type": "value",
                "data": [
                    "success": false,
                    "error": "not found",
                    "errorCode": "notFound",
                ],
            ]
        )
    }

    func testValueStorageErrorExtensionKeepsLegacyCLIValueResponseDecodable() throws {
        let response = ValueResponse(
            success: false,
            error: "Vault is locked",
            errorCode: .keychainError,
            storageErrorCode: .vaultLocked
        )

        let encoded = try JSONEncoder().encode(response)
        let legacy = try JSONDecoder().decode(LegacyValueResponse.self, from: encoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertFalse(legacy.success)
        XCTAssertEqual(legacy.errorCode, .keychainError)
        XCTAssertEqual(object["storageErrorCode"] as? String, "vaultLocked")
    }

    func testLegacyMessagesStillRoundTrip() throws {
        let requests: [IPCRequest] = [
            .auth(AuthRequest(
                credentialId: "credential-a",
                credentialLabel: "Credential A",
                fieldNames: ["token"],
                sessionId: nil,
                sessionLabel: nil,
                pid: 42
            )),
            .value(ValueRequest(
                credentialId: "credential-a",
                fieldName: "token",
                sessionId: nil
            )),
            .serviceRequests(ServiceRequestsListRequest()),
        ]

        for request in requests {
            let decoded = try JSONDecoder().decode(
                IPCRequest.self,
                from: JSONEncoder().encode(request)
            )
            switch (request, decoded) {
            case (.auth, .auth), (.value, .value), (.serviceRequests, .serviceRequests):
                break
            default:
                XCTFail("Legacy request changed case during round trip")
            }
        }

        let responses: [IPCResponse] = [
            .auth(AuthResponse(granted: true, grantId: "grant-a")),
            .value(ValueResponse(success: true, value: "value placeholder")),
            .serviceRequests(ServiceRequestsListResponse(requests: [])),
        ]

        for response in responses {
            let decoded = try JSONDecoder().decode(
                IPCResponse.self,
                from: JSONEncoder().encode(response)
            )
            switch (response, decoded) {
            case (.auth, .auth), (.value, .value), (.serviceRequests, .serviceRequests):
                break
            default:
                XCTFail("Legacy response changed case during round trip")
            }
        }
    }

    func testSessionControlMessagesRoundTrip() throws {
        let request = IPCRequest.sessionControl(SessionControlRequest(
            action: .unlock,
            passphrase: "test phrase placeholder"
        ))
        let decodedRequest = try JSONDecoder().decode(
            IPCRequest.self,
            from: JSONEncoder().encode(request)
        )
        guard case .sessionControl(let roundTrippedRequest) = decodedRequest else {
            return XCTFail("Expected sessionControl request")
        }
        XCTAssertEqual(roundTrippedRequest.action, .unlock)
        XCTAssertEqual(roundTrippedRequest.passphrase, "test phrase placeholder")

        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let response = IPCResponse.sessionControl(SessionControlResponse(
            success: true,
            state: .unlockedUntil,
            expiresAt: expiration
        ))
        let decodedResponse = try JSONDecoder().decode(
            IPCResponse.self,
            from: JSONEncoder().encode(response)
        )
        guard case .sessionControl(let roundTrippedResponse) = decodedResponse else {
            return XCTFail("Expected sessionControl response")
        }
        XCTAssertTrue(roundTrippedResponse.success)
        XCTAssertEqual(roundTrippedResponse.state, .unlockedUntil)
        XCTAssertEqual(roundTrippedResponse.expiresAt, expiration)
    }

    func testCanonicalDirectoryIsApplicationSupportKeyKeeper() {
        let expected = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("KeyKeeper", isDirectory: true)

        XCTAssertEqual(
            KeyKeeperPaths.applicationSupportDirectory.standardizedFileURL,
            expected.standardizedFileURL
        )
    }

    private func assertJSONObject<T: Encodable>(
        _ value: T,
        equals expected: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONEncoder().encode(value)
        let actual = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? NSDictionary,
            file: file,
            line: line
        )
        XCTAssertEqual(actual, expected as NSDictionary, file: file, line: line)
    }
}

private struct LegacyIPCEnvelope: Decodable {
    let type: String
    let data: LegacyEnvelopeValueResponse
}

private struct LegacyEnvelopeValueResponse: Decodable {
    let success: Bool
    let value: String?
    let error: String?
    let errorCode: ValueErrorCode?
}

private enum LegacyValueErrorCode: String, Decodable {
    case invalidRequest
    case notFound
    case noAuthorization
    case authorizationDenied
    case pendingExpired
    case keychainBlocked
    case keychainError
}

private struct LegacyValueResponse: Decodable {
    let success: Bool
    let value: String?
    let error: String?
    let errorCode: LegacyValueErrorCode?
}
