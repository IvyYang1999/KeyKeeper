import XCTest
@testable import KeyKeeperCore

final class BrowserImportProposalTests: XCTestCase {
    func testPublicProposalIDIsStableButNotTheReceiverTicket() throws {
        let ticket = String(repeating: "a", count: 64)
        let id = BrowserImportProposalID.fromTicket(ticket)
        XCTAssertEqual(id.count, 64)
        XCTAssertNotEqual(id, ticket)
        XCTAssertEqual(id, BrowserImportProposalID.fromTicket(ticket))
        XCTAssertNoThrow(try BrowserImportProposalRequest(id: id, action: .status).validate())
        XCTAssertThrowsError(try BrowserImportProposalRequest(id: "wrong", action: .status).validate())
    }

    func testProposalWireContainsMetadataAndNoReceiverCapability() throws {
        let ticket = String(repeating: "b", count: 64)
        let id = BrowserImportProposalID.fromTicket(ticket)
        let request = IPCRequest.browserImportProposal(.init(id: id, action: .open))
        guard case .browserImportProposal(let decoded) = try JSONDecoder().decode(
            IPCRequest.self, from: JSONEncoder().encode(request)) else { return XCTFail() }
        XCTAssertEqual(decoded, .init(id: id, action: .open))

        let snapshot = BrowserImportProposalSnapshot(id: id, credentialId: "oauth",
            fieldName: "client-secret", state: .approvalVisible,
            nextAction: "Approve or cancel in KeyKeeper.")
        let bytes = try JSONEncoder().encode(IPCResponse.browserImportProposal(.init(proposal: snapshot)))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(ticket))
        guard case .browserImportProposal(let response) = try JSONDecoder().decode(IPCResponse.self, from: bytes)
        else { return XCTFail() }
        XCTAssertEqual(response.proposal, snapshot)
    }
}
