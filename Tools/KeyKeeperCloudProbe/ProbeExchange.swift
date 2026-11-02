import Foundation
import CryptoKit
import CloudKit
import KeyKeeperCore

enum ProbeExchange {
    static let recordType = "KeyKeeperSyntheticHead"

    static func payload(_ record: CKRecord, runID: UUID) throws -> ProbePayload {
        guard record.recordType == recordType,
              Set(record.allKeys()) == ["vaultID", "keyID", "revisionID", "ciphertext"],
              let vaultString = record["vaultID"] as? String, let vaultID = UUID(uuidString: vaultString), vaultID == runID,
              let keyString = record["keyID"] as? String, let keyID = UUID(uuidString: keyString),
              let revisionString = record["revisionID"] as? String, let revisionID = UUID(uuidString: revisionString),
              let ciphertext = record["ciphertext"] as? Data, ciphertext.count <= CloudVaultEnvelope.maximumBytes
        else { throw ProbeFailure.corrupt }
        return .init(vaultID: vaultID, keyID: keyID, revisionID: revisionID, ciphertext: ciphertext)
    }

    static func apply(_ payload: ProbePayload, to record: CKRecord) {
        record["vaultID"] = payload.vaultID.uuidString as CKRecordValue
        record["keyID"] = payload.keyID.uuidString as CKRecordValue
        record["revisionID"] = payload.revisionID.uuidString as CKRecordValue
        record["ciphertext"] = payload.ciphertext as CKRecordValue
    }

    static func syntheticSnapshot() throws -> CloudVaultSnapshot {
        let random = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        let credential = Credential(label: "Synthetic sync fixture", notes: "Synthetic revision " + UUID().uuidString,
                                    links: [], fields: ["api-key": .init(secret: true)], security: .strict,
                                    created: "2026-11-02", updated: "2026-11-02")
        return try .init(credentials: ["synthetic-api": .init(metadata: credential, secrets: ["api-key": "fake-" + random])])
    }

    static func run(options: ProbeOptions, cloud: ProbeCloud, account: String) async throws {
        var state = try ProbeState.load(options: options, account: account, environment: cloud.environment)
        let fetched = try await cloud.fetch(runID: options.runID, account: account)
        let remote = try fetched.map { try payload($0, runID: options.runID) }
        if let pending = state.pending {
            // The previous process may have timed out after the server committed. Read first;
            // never replay a write blindly, nor discard a competing server revision.
            guard let remote else { throw ProbeFailure.pending }
            guard remote.revisionID == pending.revisionID, remote.keyID == pending.keyID,
                  remote.ciphertext == pending.ciphertext else { throw ProbeFailure.conflict }
            let snapshot = try decrypt(remote, account: account, environment: cloud.environment)
            if let expected = options.expectedDigest,
               ProbeState.digest(try snapshot.encoded()) != expected { throw ProbeFailure.conflict }
            let permit = try await cloud.verify(account: account)
            try cloud.withVerifiedAccount(permit) {
                state.confirmed = remote; state.pending = nil
                try state.save(root: options.root)
                report("recovered_committed_write", payload: remote, snapshot: snapshot)
            }
            return
        }
        if options.command == "read" {
            guard let remote else { throw ProbeFailure.corrupt }
            let snapshot = try decrypt(remote, account: account, environment: cloud.environment)
            if let expected = options.expectedDigest,
               ProbeState.digest(try snapshot.encoded()) != expected { throw ProbeFailure.conflict }
            let permit = try await cloud.verify(account: account)
            try cloud.withVerifiedAccount(permit) {
                state.confirmed = remote
                try state.save(root: options.root)
                report("read", payload: remote, snapshot: snapshot)
            }
            return
        }

        let key: SymmetricKey
        let keyID: UUID
        let record: CKRecord
        let snapshot: CloudVaultSnapshot
        if options.command == "seed" {
            guard remote == nil, state.confirmed == nil else { throw ProbeFailure.conflict }
            key = SymmetricKey(size: .bits256); keyID = UUID()
            snapshot = try syntheticSnapshot()
            record = CKRecord(recordType: recordType,
                              recordID: .init(recordName: "head", zoneID: cloud.zoneID(runID: options.runID, account: account)))
        } else if options.command == "advance" {
            guard let remote, let fetched, let confirmed = state.confirmed,
                  remote.revisionID == confirmed.revisionID, remote.ciphertext == confirmed.ciphertext else {
                throw ProbeFailure.conflict
            }
            let prior = try decrypt(remote, account: account, environment: cloud.environment)
            keyID = remote.keyID; key = try ProbeKeychain.read(runID: options.runID, keyID: keyID)
            snapshot = try syntheticSnapshot()
            guard prior.credentials["synthetic-api"]?.secrets != snapshot.credentials["synthetic-api"]?.secrets,
                  prior.credentials["synthetic-api"]?.metadata.notes != snapshot.credentials["synthetic-api"]?.metadata.notes else {
                throw ProbeFailure.corrupt
            }
            record = fetched
        } else { throw ProbeFailure.invalidArguments }
        let revision = UUID()
        let context = CloudVaultEnvelopeContext(container: ProbeOptions.container, environment: cloud.environment,
                                               account: account, vaultID: options.runID, keyID: keyID, revisionID: revision)
        let candidate = ProbePayload(vaultID: options.runID, keyID: keyID, revisionID: revision,
                                     ciphertext: try CloudVaultEnvelope.seal(snapshot, key: key, context: context))
        // Persist only authenticated ciphertext before the first external write. On any error,
        // confirmed source and pending candidate remain available for readback/recovery.
        let writePermit = try await cloud.verify(account: account)
        try cloud.withVerifiedAccount(writePermit) {
            state.pending = candidate
            try state.save(root: options.root)
        }
        if options.command == "seed" {
            try cloud.withVerifiedAccount(writePermit) {
                try ProbeKeychain.create(runID: options.runID, keyID: keyID, key: key)
            }
            try await cloud.createZone(runID: options.runID, account: account)
        }
        apply(candidate, to: record)
        try await cloud.save(record, account: account)
        guard let readback = try await cloud.fetch(runID: options.runID, account: account) else { throw ProbeFailure.pending }
        let committed = try payload(readback, runID: options.runID)
        guard committed.revisionID == candidate.revisionID, committed.ciphertext == candidate.ciphertext else {
            throw ProbeFailure.conflict
        }
        let restored = try decrypt(committed, account: account, environment: cloud.environment)
        guard try restored.encoded() == snapshot.encoded() else { throw ProbeFailure.corrupt }
        let permit = try await cloud.verify(account: account)
        try cloud.withVerifiedAccount(permit) {
            state.confirmed = committed; state.pending = nil
            try state.save(root: options.root)
            report(options.command, payload: committed, snapshot: restored)
        }
    }

    static func decrypt(_ payload: ProbePayload, account: String, environment: String) throws -> CloudVaultSnapshot {
        let key = try ProbeKeychain.read(runID: payload.vaultID, keyID: payload.keyID)
        return try CloudVaultEnvelope.open(payload.ciphertext, key: key,
                                          expectedContext: payload.context(account: account, environment: environment))
    }

    static func report(_ phase: String, payload: ProbePayload, snapshot: CloudVaultSnapshot) {
        guard let bytes = try? snapshot.encoded() else { return }
        print("PASS \(phase) revision=\(payload.revisionID.uuidString) snapshot_sha256=\(ProbeState.digest(bytes)) credentials=\(snapshot.credentials.count) local_grants_transferred=0")
    }

    static func selfTest() throws {
        let runID = UUID(), keyID = UUID(), revisionID = UUID()
        let key = SymmetricKey(size: .bits256)
        let snapshot = try syntheticSnapshot(), other = try syntheticSnapshot()
        guard try snapshot.encoded() != other.encoded(),
              snapshot.credentials["synthetic-api"]?.metadata.notes != other.credentials["synthetic-api"]?.metadata.notes else {
            throw ProbeFailure.corrupt
        }
        let context = CloudVaultEnvelopeContext(container: ProbeOptions.container, environment: "Production", account: "synthetic-account",
                                               vaultID: runID, keyID: keyID, revisionID: revisionID)
        let value = ProbePayload(vaultID: runID, keyID: keyID, revisionID: revisionID,
                                 ciphertext: try CloudVaultEnvelope.seal(snapshot, key: key, context: context))
        let record = CKRecord(recordType: recordType)
        apply(value, to: record)
        let parsed = try payload(record, runID: runID)
        guard try CloudVaultEnvelope.open(parsed.ciphertext, key: key, expectedContext: context).encoded() == snapshot.encoded() else {
            throw ProbeFailure.corrupt
        }
        record["grants"] = "forbidden" as CKRecordValue
        do { _ = try payload(record, runID: runID); throw ProbeFailure.unavailable }
        catch ProbeFailure.corrupt { }
        let state = ProbeState(schema: 1, runID: runID, accountHash: "synthetic-hash", environment: "Production", pending: value)
        let encoded = try state.encoded()
        let secret = snapshot.credentials["synthetic-api"]!.secrets["api-key"]!
        guard !String(decoding: encoded, as: UTF8.self).contains(secret),
              !String(decoding: encoded, as: UTF8.self).contains("synthetic-account") else { throw ProbeFailure.corrupt }
        try ProbeState.selfTest(payload: value)
    }
}
