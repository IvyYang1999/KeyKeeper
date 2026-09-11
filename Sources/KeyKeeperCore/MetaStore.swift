import Foundation

/// Load and save of meta.json, as a seam for tests that simulate a failed write.
public protocol MetaStoring {
    func load() throws -> MetaFile
    func save(_ meta: MetaFile) throws
}

public final class MetaStore: Sendable, MetaStoring {
    /// Where the metadata lives; surfaced in the GUI when it cannot be read.
    public let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("meta.json")
    }

    public static var `default`: MetaStore {
        let dir = KeyKeeperPaths.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return MetaStore(directory: dir)
    }

    public func load() throws -> MetaFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MetaFile()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(MetaFile.self, from: data)
    }

    public func save(_ meta: MetaFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        try data.write(to: fileURL, options: .atomic)
    }
}
