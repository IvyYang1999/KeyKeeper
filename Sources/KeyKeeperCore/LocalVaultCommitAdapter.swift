import Foundation
import Darwin

/// Raw IO owned only by the local commit coordinator. It deliberately has no gate:
/// the coordinator holds the outer gate while ordinary stores are blocked.
final class LocalVaultCommitAdapter: LocalVaultCommitStorage {
    let metaStore: MetaStore
    let valuesIO: KeychainBlobIO
    let integrityIO: KeychainBlobIO
    let approvals: ApprovalStore
    let namespace: String

    init(metaStore: MetaStore, valuesIO: KeychainBlobIO, integrityIO: KeychainBlobIO,
         approvalsIO: KeychainBlobIO, namespace: String) {
        self.metaStore = metaStore; self.valuesIO = valuesIO; self.integrityIO = integrityIO
        self.approvals = ApprovalStore(io: approvalsIO); self.namespace = namespace
    }

    func readImage() throws -> LocalVaultImage {
        LocalVaultImage(metadata: try readMetadata(), values: try valuesIO.readBlobWithoutInteraction())
    }

    func snapshot() throws -> CloudVaultSnapshot {
        let image = try readImage()
        return try decoded(image).snapshot
    }

    func prepare(_ desired: CloudVaultSnapshot, id: UUID, generation: UUID) throws -> LocalVaultCommitPlan {
        let before = try readImage(), source = try decoded(before)
        _ = try desired.encoded()
        var meta = source.meta
        meta.credentials = desired.credentials.mapValues(\.metadata)
        meta.storeInitialized = true
        let blob = try valuesReplacing(source, with: desired)
        let after = try LocalVaultImage(metadata: metaStore.preparedSignedData(meta),
            values: CloudVaultSnapshot.encode(blob))
        let plan = LocalVaultCommitPlan(id: id, namespace: namespace, expectedGeneration: generation,
            before: before, after: after, changedCredentialIDs: try changedIDs(source.snapshot, desired))
        try validate(plan)
        return plan
    }

    func validate(_ plan: LocalVaultCommitPlan) throws {
        guard plan.namespace == namespace, plan.after.values != nil,
              try approvals.mode() == .enforced else { throw LocalVaultCommitError.invalidPlan }
        let before = try decoded(plan.before), after = try decoded(plan.after)
        guard after.meta.storeInitialized == true,
              plan.changedCredentialIDs == (try changedIDs(before.snapshot, after.snapshot)),
              try CloudVaultSnapshot.encode(after.blob) == CloudVaultSnapshot.encode(valuesReplacing(before, with: after.snapshot))
        else { throw LocalVaultCommitError.invalidPlan }
    }

    private func changedIDs(_ before: CloudVaultSnapshot, _ after: CloudVaultSnapshot) throws -> [String] {
        try Set(before.credentials.keys).union(after.credentials.keys).sorted().filter {
            try before.credentials[$0].map(CloudVaultSnapshot.encode) != after.credentials[$0].map(CloudVaultSnapshot.encode)
        }
    }

    /// Remove only the fields owned by the previous metadata. Unreferenced values are
    /// historical recovery material; a new field must not overwrite an orphan by accident.
    private func valuesReplacing(_ before: Decoded, with desired: CloudVaultSnapshot) throws -> KeychainBlobStore.Blob {
        // A missing marker describes an absence, never permission to erase a known value.
        // Keep this check here so preparation AND independent journal validation enforce it.
        // Removing a field or credential explicitly remains a separate operation.
        for (id, bundle) in desired.credentials {
            let previous = before.snapshot.credentials[id]?.secrets ?? [:]
            guard bundle.missingSecretFields.allSatisfy({ previous[$0] == nil }) else {
                throw LocalVaultCommitError.invalidPlan
            }
        }
        var preserved = before.blob.credentials
        for (id, bundle) in before.snapshot.credentials {
            for field in bundle.secrets.keys { preserved[id]?.removeValue(forKey: field) }
            if preserved[id]?.isEmpty == true { preserved.removeValue(forKey: id) }
        }
        for (id, bundle) in desired.credentials {
            for field in bundle.metadata.fields.keys {
                if let orphan = preserved[id]?[field], bundle.secrets[field] != orphan {
                    throw LocalVaultCommitError.conflict
                }
            }
            for (field, value) in bundle.secrets { preserved[id, default: [:]][field] = value }
        }
        return .init(version: 1, credentials: preserved)
    }

    func writeValues(_ data: Data, replacingExisting: Bool) throws {
        try valuesIO.writeBlob(data, replacingExisting: replacingExisting)
    }

    func revokeApprovals(for ids: [String]) throws {
        for id in ids where try approvals.hasApprovals(forCredential: id) {
            try approvals.revokeAll(forCredential: id)
        }
    }

    func approvalsAreRevoked(for ids: [String]) throws -> Bool {
        let affected = Set(ids)
        return try approvals.all().allSatisfy { approval in
            approval.target.credentialId.map { !affected.contains($0) } ?? true
        }
    }

    func writeMetadata(_ data: Data) throws {
        // .atomic preserves the old file until rename; fsync makes the new file and
        // its directory durable before the journal can record completion.
        try data.write(to: metaStore.fileURL, options: .atomic)
        for url in [metaStore.fileURL, metaStore.fileURL.deletingLastPathComponent()] {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw LocalVaultCommitError.unavailable }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw LocalVaultCommitError.unavailable }
        }
    }

    private func readMetadata() throws -> Data? {
        let descriptor = open(metaStore.fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw LocalVaultCommitError.unavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= LocalVaultJournal.maximumBytes else { throw LocalVaultCommitError.unavailable }
        let bytes = try handle.read(upToCount: LocalVaultJournal.maximumBytes + 1) ?? Data()
        guard bytes.count <= LocalVaultJournal.maximumBytes else { throw LocalVaultCommitError.unavailable }
        return bytes
    }

    struct Decoded {
        let meta: MetaFile
        let blob: KeychainBlobStore.Blob
        let snapshot: CloudVaultSnapshot
    }

    func decoded(_ image: LocalVaultImage) throws -> Decoded {
        guard let data = image.metadata,
              let key = try MetaIntegrityKey.existing(io: integrityIO, allowInteraction: false)
        else { throw LocalVaultCommitError.invalidPlan }
        let meta: MetaFile = try strictDecode(data)
        guard meta.version == 1, MetaIntegrity.verify(meta, key: key) == .intact else {
            throw LocalVaultCommitError.invalidPlan
        }
        let blob: KeychainBlobStore.Blob
        if let bytes = image.values { blob = try strictDecode(bytes) }
        else {
            // Missing an entire store is not the same as a field missing from a readable
            // store, even in legacy metadata without an initialization marker.
            guard meta.storeInitialized != true,
                  !meta.credentials.values.contains(where: { $0.fields.values.contains(where: \.secret) })
            else { throw CredentialStorageError.missingStore }
            blob = .init(version: 1, credentials: [:])
        }
        guard blob.version == 1 else { throw LocalVaultCommitError.invalidPlan }
        var bundles: [String: CloudCredentialBundle] = [:]
        for (id, credential) in meta.credentials {
            var secrets: [String: String] = [:]
            var missing: [String] = []
            for (field, definition) in credential.fields where definition.secret {
                if let value = blob.credentials[id]?[field] { secrets[field] = value }
                else { missing.append(field) }
            }
            bundles[id] = .init(metadata: credential, secrets: secrets, missingSecretFields: missing.sorted())
        }
        return try Decoded(meta: meta, blob: blob, snapshot: CloudVaultSnapshot(credentials: bundles))
    }

    /// Formatting is irrelevant, but unknown schema cannot silently disappear on re-encode.
    private func strictDecode<T: Codable>(_ data: Data) throws -> T {
        guard data.count <= LocalVaultJournal.maximumBytes else { throw LocalVaultCommitError.invalidPlan }
        let decoded = try JSONDecoder().decode(T.self, from: data)
        let input = try JSONSerialization.jsonObject(with: data) as AnyObject
        let output = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as AnyObject
        guard input.isEqual(output) else { throw LocalVaultCommitError.invalidPlan }
        return decoded
    }
}
