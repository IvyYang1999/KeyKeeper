import Foundation

/// Load and save of meta.json, as a seam for tests that simulate a failed write.
public protocol MetaStoring {
    func load() throws -> MetaFile
    func loadForUse() throws -> MetaFile
    func prepareForMutation() throws -> MetaFile
    func save(_ meta: MetaFile) throws
}

extension MetaStoring {
    public func loadForUse() throws -> MetaFile { try load() }
    public func prepareForMutation() throws -> MetaFile { try loadForUse() }
}

public enum MetaStoreError: Error, Equatable, LocalizedError {
    case integrityKeyMissing
    case metadataTampered

    public var errorDescription: String? {
        switch self {
        case .integrityKeyMissing: "The metadata integrity key is missing. The existing metadata was kept unchanged."
        case .metadataTampered: "The credential metadata could not be verified. Review it in KeyKeeper before making changes."
        }
    }
}

public final class MetaStore: Sendable, MetaStoring {
    /// Where the metadata lives; surfaced in the GUI when it cannot be read.
    public let fileURL: URL
    /// Where the integrity key lives. Nil disables signing entirely (tests that do not care).
    private let integrityIO: KeychainBlobIO?

    public init(directory: URL, integrityIO: KeychainBlobIO? = nil) {
        self.fileURL = directory.appendingPathComponent("meta.json")
        self.integrityIO = integrityIO
    }

    public static var `default`: MetaStore {
        let dir = KeyKeeperPaths.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return MetaStore(directory: dir, integrityIO: SecItemBlobIO(service: MetaIntegrityKey.service))
    }

    /// The metadata, and whether it is still the file KeyKeeper wrote.
    ///
    /// `.unsigned` means no key has ever been made on this machine — a genuinely old file. Once a
    /// key exists, a file without a MAC is `.tampered`, because removing the line would otherwise
    /// be a way to switch the check off.
    public func loadVerified() throws -> (meta: MetaFile, verdict: MetaIntegrity.Verdict) {
        let loaded = try verifiedContents()
        return (loaded.meta, loaded.verdict)
    }

    /// Admission is read-only and must not display a Keychain authorization prompt.
    public func loadForUse() throws -> MetaFile {
        let loaded = try verifiedContents()
        guard loaded.verdict != .tampered else { throw MetaStoreError.metadataTampered }
        return loaded.meta
    }

    /// Bootstrap genuine legacy metadata before callers can mutate any credential values.
    /// A failure establishing its first signature therefore leaves values untouched.
    public func prepareForMutation() throws -> MetaFile {
        let loaded = try verifiedContents()
        guard loaded.verdict != .tampered else { throw MetaStoreError.metadataTampered }
        guard integrityIO != nil, loaded.verdict == .unsigned else { return loaded.meta }
        try save(loaded.meta)
        return try loadForUse()
    }

    private func verifiedContents() throws -> (meta: MetaFile, verdict: MetaIntegrity.Verdict, key: Data?) {
        let meta = try load()
        guard let integrityIO else { return (meta, .unsigned, nil) }
        guard let key = try MetaIntegrityKey.existing(io: integrityIO, allowInteraction: false) else {
            guard meta.integrity == nil else { throw MetaStoreError.integrityKeyMissing }
            return (meta, .unsigned, nil)
        }
        // A key exists, so this machine signs its metadata. A file with no MAC at that point was
        // not written by an old build — somebody removed the line.
        guard meta.integrity?.isEmpty == false else { return (meta, .tampered, key) }
        return (meta, MetaIntegrity.verify(meta, key: key), key)
    }

    public func load() throws -> MetaFile {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return MetaFile()
        }
        return try JSONDecoder().decode(MetaFile.self, from: data)
    }

    public func save(_ meta: MetaFile) throws {
        guard let integrityIO else { try write(meta); return }
        let current = try verifiedContents()
        guard current.verdict != .tampered else { throw MetaStoreError.metadataTampered }
        // Even a caller holding an earlier signed snapshot cannot cause a replacement key.
        guard current.key != nil || meta.integrity == nil else { throw MetaStoreError.integrityKeyMissing }
        let key = try current.key ?? MetaIntegrityKey.loadOrCreate(io: integrityIO, allowInteraction: false)
        try signAndWrite(meta, key: key)
    }

    /// Only the owner-confirmed review flow may re-sign changed metadata. This does not
    /// restore a lost/denied key or claim that damaged credential values were recovered.
    public func trustCurrentMetadata() throws {
        let meta = try load()
        guard let integrityIO else { try write(meta); return }
        let existing = try MetaIntegrityKey.existing(io: integrityIO, allowInteraction: false)
        guard existing != nil || meta.integrity == nil else { throw MetaStoreError.integrityKeyMissing }
        let key = try existing ?? MetaIntegrityKey.loadOrCreate(io: integrityIO, allowInteraction: false)
        try signAndWrite(meta, key: key)
    }

    private func signAndWrite(_ meta: MetaFile, key: Data) throws {
        var signed = meta
        signed.integrity = try MetaIntegrity.mac(for: signed, key: key)
        try write(signed)
    }

    private func write(_ meta: MetaFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        try data.write(to: fileURL, options: .atomic)
    }
}
