import Foundation

/// One edit to names or notes, and who made it.
public struct MetadataChangeRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var timestamp: Date
    /// Display name of the calling process ("claude", "com.openai.codex").
    public var caller: String
    /// Group ID after the edit.
    public var groupId: String
    public var label: String
    public var changes: [MetadataChange]

    public init(id: String = UUID().uuidString, caller: String, groupId: String, label: String,
                changes: [MetadataChange], timestamp: Date = Date()) {
        self.id = id
        self.timestamp = timestamp
        self.caller = caller
        self.groupId = groupId
        self.label = label
        self.changes = changes
    }
}

/// Edits made without asking are written down here so the person can see them later
/// (yyt 2026-09-11: "no prompts — just tell me what changed"). Keeps the latest 200.
public final class MetadataChangeLog: Sendable {
    static let limit = 200
    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("metadata-changes.json")
    }

    public static var `default`: MetadataChangeLog {
        MetadataChangeLog(directory: KeyKeeperPaths.applicationSupportDirectory)
    }

    public func records() throws -> [MetadataChangeRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([MetadataChangeRecord].self, from: Data(contentsOf: fileURL))
    }

    public func append(_ record: MetadataChangeRecord) throws {
        var all = try records()
        all.append(record)
        if all.count > Self.limit { all.removeFirst(all.count - Self.limit) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(all).write(to: fileURL, options: .atomic)
    }
}
