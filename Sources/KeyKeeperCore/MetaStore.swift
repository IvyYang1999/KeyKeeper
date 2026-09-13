import Foundation

/// Load and save of meta.json, as a seam for tests that simulate a failed write.
public protocol MetaStoring {
    func load() throws -> MetaFile
    func save(_ meta: MetaFile) throws
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
        let meta = try load()
        guard let integrityIO, let key = try? MetaIntegrityKey.existing(io: integrityIO) else {
            return (meta, .unsigned)
        }
        // A key exists, so this machine signs its metadata. A file with no MAC at that point was
        // not written by an old build — somebody removed the line.
        guard meta.integrity != nil else { return (meta, .tampered) }
        return (meta, MetaIntegrity.verify(meta, key: key))
    }

    public func load() throws -> MetaFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MetaFile()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(MetaFile.self, from: data)
    }

    public func save(_ meta: MetaFile) throws {
        var signed = meta
        if let integrityIO, let key = try? MetaIntegrityKey.loadOrCreate(io: integrityIO) {
            signed.integrity = try? MetaIntegrity.mac(for: signed, key: key)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(signed)
        try data.write(to: fileURL, options: .atomic)
    }
}
