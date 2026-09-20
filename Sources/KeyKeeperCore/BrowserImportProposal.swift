import Foundation
import CryptoKit

public enum BrowserImportProposalState: String, Codable, Sendable, Equatable {
    case receiverReady
    case pasteReceived
    case approvalVisible
    case committing
    case committed
    case expired
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .committed, .expired, .cancelled, .failed: true
        default: false
        }
    }
}

/// Metadata-only truth shared by CLI, the local paste page and the App. Never contains a value,
/// preview, hash of the value, caller grant, or the receiver capability ticket.
public struct BrowserImportProposalSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var credentialId: String
    public var fieldName: String
    public var state: BrowserImportProposalState
    public var deadline: Date?
    public var nextAction: String?
    public var errorCode: ClipboardSaveError?

    public init(id: String, credentialId: String, fieldName: String,
                state: BrowserImportProposalState, deadline: Date? = nil,
                nextAction: String? = nil, errorCode: ClipboardSaveError? = nil) {
        self.id = id
        self.credentialId = credentialId
        self.fieldName = fieldName
        self.state = state
        self.deadline = deadline
        self.nextAction = nextAction
        self.errorCode = errorCode
    }
}

public enum BrowserImportProposalAction: String, Codable, Sendable, Equatable {
    case status
    case open
}

public struct BrowserImportProposalRequest: Codable, Sendable, Equatable {
    public var id: String
    public var action: BrowserImportProposalAction
    public init(id: String, action: BrowserImportProposalAction) { self.id = id; self.action = action }

    public func validate() throws {
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw BrowserImportProposalError.invalidID
        }
    }
}

public struct BrowserImportProposalResponse: Codable, Sendable, Equatable {
    public var proposal: BrowserImportProposalSnapshot?
    public var error: BrowserImportProposalError?
    public init(proposal: BrowserImportProposalSnapshot? = nil, error: BrowserImportProposalError? = nil) {
        self.proposal = proposal; self.error = error
    }
}

public enum BrowserImportProposalError: String, Error, Codable, Sendable, Equatable, LocalizedError {
    case invalidID
    case notFound
    case noLongerOpen
    public var errorDescription: String? {
        switch self {
        case .invalidID: "Proposal ID must be 64 lowercase hexadecimal characters."
        case .notFound: "Proposal not found. It may have expired from local history."
        case .noLongerOpen: "This proposal is already finished and cannot be reopened."
        }
    }
}

public enum BrowserImportProposalID {
    /// The public ID is a one-way name for a random 256-bit receiver ticket. It cannot authorize
    /// HTTP access and is safe to show in CLI output and process arguments.
    public static func fromTicket(_ ticket: String) -> String {
        SHA256.hash(data: Data(ticket.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
