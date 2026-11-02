import XCTest
@testable import KeyKeeperCore

final class VaultAccessGateTests: XCTestCase {
    private enum Failure: Error { case injected }

    func testAdmissionFailureDoesNotRunBodyAndStaysBlockedUntilRecovery() throws {
        var admissions = 0
        var available = false
        let gate = VaultAccessGate(admission: {
            admissions += 1
            if !available { throw Failure.injected }
        })
        var accesses = 0
        XCTAssertThrowsError(try gate.withAccess { accesses += 1 })
        XCTAssertThrowsError(try gate.withAccess { accesses += 1 })
        XCTAssertEqual(accesses, 0)
        XCTAssertEqual(admissions, 1)
        available = true
        try gate.withRecovery {}
        try gate.withAccess { accesses += 1 }
        XCTAssertEqual(accesses, 1)
    }

    func testOutermostAccessRechecksAdmissionAndNestedStoresReuseLease() throws {
        var available = true
        var checks = 0
        let gate = VaultAccessGate(admission: {
            checks += 1
            if !available { throw Failure.injected }
        })
        try gate.withAccess {
            try gate.withAccess {}
            _ = try gate.captureEpoch()
        }
        XCTAssertEqual(checks, 1)
        available = false
        XCTAssertThrowsError(try gate.withAccess {})
        XCTAssertEqual(checks, 2)
        available = true
        XCTAssertThrowsError(try gate.withAccess {}, "A failed journal check needs explicit recovery")
        XCTAssertEqual(checks, 2)
        try gate.withRecovery {}
        XCTAssertNoThrow(try gate.withAccess {})
        XCTAssertEqual(checks, 3)
    }

    func testCommitInvalidatesPendingEpochAndFailureBlocksAccess() throws {
        let gate = VaultAccessGate()
        let old = try gate.captureEpoch()
        try gate.withCommit {}
        XCTAssertThrowsError(try gate.withAccess(expectedEpoch: old) {})
        let current = try gate.captureEpoch()
        XCTAssertGreaterThan(current, old)
        XCTAssertThrowsError(try gate.withCommit { throw Failure.injected })
        XCTAssertThrowsError(try gate.withAccess {})
        try gate.withRecovery {}
        XCTAssertThrowsError(try gate.withAccess(expectedEpoch: current) {})
        XCTAssertNoThrow(try gate.withAccess {})
    }

    func testRecursiveNormalAccessWorksButTransactionCannotUsePublicAccess() throws {
        let gate = VaultAccessGate()
        XCTAssertEqual(try gate.withAccess { try gate.withAccess { 42 } }, 42)
        try gate.withCommit {
            XCTAssertThrowsError(try gate.withAccess {})
        }
    }

    func testCommitWaitsForWholeOrdinaryOperation() throws {
        let gate = VaultAccessGate()
        let ordinaryEntered = DispatchSemaphore(value: 0)
        let ordinaryRelease = DispatchSemaphore(value: 0)
        let transactionEntered = DispatchSemaphore(value: 0)
        let finished = expectation(description: "workers finish")
        finished.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            try? gate.withAccess {
                ordinaryEntered.signal()
                _ = ordinaryRelease.wait(timeout: .now() + 3)
            }
        }
        XCTAssertEqual(ordinaryEntered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            try? gate.withCommit { transactionEntered.signal() }
        }
        XCTAssertEqual(transactionEntered.wait(timeout: .now() + 0.05), .timedOut)
        ordinaryRelease.signal()
        XCTAssertEqual(transactionEntered.wait(timeout: .now() + 3), .success)
        wait(for: [finished], timeout: 3)
    }
}
