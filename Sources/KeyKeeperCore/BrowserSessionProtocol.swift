import Foundation

public struct BrowserSessionRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case list, save, open, stop, delete }
    public let action: Action
    public let id: String?
    public let snapshot: BrowserSessionImport?
    public init(action: Action, id: String? = nil, snapshot: BrowserSessionImport? = nil) {
        self.action = action; self.id = id; self.snapshot = snapshot
    }
    public func validate() throws {
        switch action {
        case .list:
            guard id == nil, snapshot == nil else { throw BrowserSessionError.invalidImport }
        case .save:
            guard id == nil, let snapshot else { throw BrowserSessionError.invalidImport }
            try snapshot.validate()
        case .open, .stop, .delete:
            guard let id, UUID(uuidString: id) != nil, snapshot == nil else { throw BrowserSessionError.invalidImport }
        }
    }
}

public struct BrowserSessionResponse: Codable, Sendable {
    public let success: Bool
    public let sessions: [BrowserSessionSummary]
    public let activeIDs: [String]
    public let errorCode: BrowserSessionError?
    public init(success: Bool, sessions: [BrowserSessionSummary] = [], activeIDs: [String] = [], errorCode: BrowserSessionError? = nil) {
        self.success = success; self.sessions = sessions; self.activeIDs = activeIDs; self.errorCode = errorCode
    }
}
