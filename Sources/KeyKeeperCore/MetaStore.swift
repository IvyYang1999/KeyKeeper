import Foundation

public final class MetaStore: Sendable {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("meta.json")
    }

    public static var `default`: MetaStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyKeeper")
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
