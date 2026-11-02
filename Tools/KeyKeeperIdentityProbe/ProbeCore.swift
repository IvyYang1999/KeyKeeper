import CryptoKit
import Foundation
import KeyKeeperCore

enum ProbeFailure: Error {
    case rejected, integrityUnavailable, conflict, isolation, signature, deadline, io, keychain(Int32)
    var category: String {
        switch self {
        case .rejected: return "validation"
        case .integrityUnavailable: return "integrity-unavailable"
        case .conflict: return "destination-conflict"
        case .isolation: return "isolation"
        case .signature: return "signature"
        case .deadline: return "deadline"
        case .io: return "io"
        case .keychain: return "keychain"
        }
    }
}

enum ProbePhase: String, CaseIterable {
    case startup, selfTest = "self-test", isolation
    case producerIdentity = "producer-identity", sourceCreate = "source-create"
    case integrityCreate = "integrity-create", metadataCreate = "metadata-create"
    case sourceReadback = "source-readback", firstTransfer = "first-transfer"
    case replayTransfer = "replay-transfer", sourceRecovery = "source-recovery"
    case consumerIdentity = "consumer-identity", sourceAccess = "source-access"
    case receiveTransfer = "receive-transfer", destinationCommit = "destination-commit"
    case destinationReadback = "destination-readback"
}

enum ProbeDiagnostics {
    static func phase(_ phase: ProbePhase) {
        FileHandle.standardError.write(Data("PROBE_STAGE \(phase.rawValue)\n".utf8))
    }

    /// Child stderr is never forwarded verbatim: only exact fixed diagnostic tokens survive.
    static func forwardReceiverFailure(_ data: Data) {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else { return }
        let phases = ProbePhase.allCases.map { "PROBE_STAGE \($0.rawValue)" }
        let categories = ["validation", "integrity-unavailable", "destination-conflict", "isolation",
                          "signature", "deadline", "io", "keychain", "unexpected"]
            .map { "FAIL identity probe: \($0)" }
        let allowed = Set(phases + categories)
        for line in text.split(separator: "\n").map(String.init) where allowed.contains(line) {
            FileHandle.standardError.write(Data("RECEIVER \(line)\n".utf8))
        }
    }
}

struct Transfer: Codable {
    let version: Int
    let runID: String
    let snapshot: Data
    let metadata: Data
    let mac: Data
    let integrityKey: Data
}

enum ProbeCore {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func metadata(_ snapshot: CloudVaultSnapshot) throws -> Data {
        try encode(snapshot.credentials.mapValues(\.metadata))
    }

    static func authenticatedBytes(runID: String, snapshot: Data, metadata: Data) -> Data {
        var data = Data("KeyKeeperIdentityProbe/v1/\(runID)/".utf8)
        for part in [snapshot, metadata] {
            var length = UInt64(part.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(part)
        }
        return data
    }

    static func transfer(runID: String, snapshot: Data, metadata: Data, key: Data?) throws -> Data {
        guard let key, key.count == 32 else { throw ProbeFailure.integrityUnavailable }
        let bytes = authenticatedBytes(runID: runID, snapshot: snapshot, metadata: metadata)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: key)))
        return try encode(Transfer(version: 1, runID: runID, snapshot: snapshot,
                                   metadata: metadata, mac: mac, integrityKey: key))
    }

    static func validate(_ wire: Data, runID: String) throws -> Data {
        guard wire.count <= 1_500_000 else { throw ProbeFailure.rejected }
        let message = try JSONDecoder().decode(Transfer.self, from: wire)
        guard message.version == 1, message.runID == runID, message.integrityKey.count == 32,
              try encode(message) == wire else { throw ProbeFailure.rejected }
        let bytes = authenticatedBytes(runID: runID, snapshot: message.snapshot, metadata: message.metadata)
        guard HMAC<SHA256>.isValidAuthenticationCode(message.mac, authenticating: bytes,
                                                     using: SymmetricKey(data: message.integrityKey)) else {
            throw ProbeFailure.rejected
        }
        let snapshot = try CloudVaultSnapshot.decode(message.snapshot)
        guard try metadata(snapshot) == message.metadata else { throw ProbeFailure.rejected }
        return message.snapshot
    }

    /// Validation precedes destination access. Existing unequal data is never overwritten.
    static func commit(_ wire: Data, runID: String, read: () throws -> Data?, create: (Data) throws -> Void) throws -> Bool {
        let snapshot = try validate(wire, runID: runID)
        if let existing = try read() {
            guard existing == snapshot else { throw ProbeFailure.conflict }
            return false
        }
        try create(snapshot)
        guard try read() == snapshot else { throw ProbeFailure.rejected }
        return true
    }

    static func sample(secret: String = "synthetic-only") throws -> CloudVaultSnapshot {
        let credential = Credential(label: "Synthetic identity migration", notes: "No real credentials",
            links: [], fields: ["api-key": CredentialField(secret: true)], security: .strict,
            created: "2026-11-02", updated: "2026-11-02", injectOnly: true)
        return try CloudVaultSnapshot(credentials: ["synthetic": CloudCredentialBundle(
            metadata: credential, secrets: ["api-key": secret])])
    }

    static func selfTest() throws {
        let runID = UUID().uuidString
        let snapshot = try sample()
        let encoded = try snapshot.encoded()
        let meta = try metadata(snapshot)
        let wire = try transfer(runID: runID, snapshot: encoded, metadata: meta, key: Data(repeating: 7, count: 32))
        var target: Data?
        var writes = 0
        func apply(_ input: Data) throws -> Bool {
            try commit(input, runID: runID, read: { target }, create: { target = $0; writes += 1 })
        }
        func rejected(_ body: () throws -> Void) throws {
            let before = writes
            do { try body() } catch {
                guard writes == before else { throw ProbeFailure.rejected }; return
            }
            throw ProbeFailure.rejected
        }
        // First red boundary: missing integrity evidence must never admit a write.
        try rejected { _ = try transfer(runID: runID, snapshot: encoded, metadata: meta, key: nil) }
        try rejected { _ = try apply(wire.dropLast()) }
        var object = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
        object.removeValue(forKey: "metadata")
        try rejected { _ = try apply(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) }
        let message = try JSONDecoder().decode(Transfer.self, from: wire)
        let corrupted = try encode(Transfer(version: 1, runID: runID, snapshot: encoded,
            metadata: meta, mac: Data(repeating: 0, count: 32), integrityKey: message.integrityKey))
        try rejected { _ = try apply(corrupted) }
        // A source integrity read that throws is not downgraded to "missing" or a new key.
        func prepare(readIntegrity: () throws -> Data?) throws -> Data {
            try transfer(runID: runID, snapshot: encoded, metadata: meta, key: readIntegrity())
        }
        try rejected { _ = try apply(prepare(readIntegrity: { throw ProbeFailure.integrityUnavailable })) }
        var snapshotObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        snapshotObject["credentials"] = ["synthetic": ["metadata": snapshot.credentials["synthetic"]!.metadata.label]]
        let incomplete = try JSONSerialization.data(withJSONObject: snapshotObject, options: [.sortedKeys])
        try rejected { _ = try apply(transfer(runID: runID, snapshot: incomplete, metadata: meta, key: message.integrityKey)) }
        try rejected { _ = try apply(transfer(runID: runID, snapshot: encoded, metadata: Data("{}".utf8), key: message.integrityKey)) }
        try rejected { _ = try commit(wire, runID: runID, read: { throw ProbeFailure.integrityUnavailable }, create: { _ in writes += 1 }) }
        guard try apply(wire), writes == 1, target == encoded else { throw ProbeFailure.rejected }
        guard try !apply(wire), writes == 1 else { throw ProbeFailure.rejected }
        target = Data("existing-different-target".utf8)
        try rejected { _ = try apply(wire) }
        guard target == Data("existing-different-target".utf8), writes == 1 else { throw ProbeFailure.rejected }
        print("PASS synthetic validation: missing integrity, truncation, missing field, HMAC mismatch, denied read, conflict, replay")
    }
}
