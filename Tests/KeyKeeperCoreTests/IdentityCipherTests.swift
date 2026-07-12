import Foundation
import Security
import XCTest
@testable import KeyKeeperCore

final class IdentityCipherTests: XCTestCase {
    private let magicRange = 0..<8
    private let iterationRange = 8..<12
    private let saltRange = 12..<28
    private let nonceRange = 28..<40
    private let headerByteCount = 40
    private let tagByteCount = 16

    func testSealRejectsEmptyPassphrase() {
        XCTAssertThrowsError(
            try IdentityCipher.seal(Data("plaintext placeholder".utf8), passphrase: "")
        ) { error in
            guard case IdentityCipherError.emptyPassphrase = error else {
                return XCTFail("Expected IdentityCipherError.emptyPassphrase")
            }
        }
    }

    func testOpenRejectsEmptyPassphrase() throws {
        let container = try IdentityCipher.seal(
            Data("plaintext placeholder".utf8),
            passphrase: "accepted phrase placeholder"
        )

        XCTAssertThrowsError(try IdentityCipher.open(container, passphrase: "")) { error in
            guard case IdentityCipherError.emptyPassphrase = error else {
                return XCTFail("Expected IdentityCipherError.emptyPassphrase")
            }
        }
    }

    func testSealUsesIndependentRandomSaltAndNonce() throws {
        let plaintext = Data("private identity placeholder".utf8)
        let first = try IdentityCipher.seal(plaintext, passphrase: "phrase placeholder")
        let second = try IdentityCipher.seal(plaintext, passphrase: "phrase placeholder")

        XCTAssertNotEqual(first.subdata(in: saltRange), second.subdata(in: saltRange))
        XCTAssertNotEqual(first.subdata(in: nonceRange), second.subdata(in: nonceRange))
        XCTAssertEqual(try IdentityCipher.open(first, passphrase: "phrase placeholder"), plaintext)
        XCTAssertEqual(try IdentityCipher.open(second, passphrase: "phrase placeholder"), plaintext)
    }

    func testRejectsWrongPassphrase() throws {
        let sealed = try makeContainer()

        XCTAssertThrowsError(try IdentityCipher.open(sealed, passphrase: "rejected phrase placeholder"))
    }

    func testRejectsTamperedMagic() throws {
        try assertRejectedAfterFlippingByte(in: magicRange)
    }

    func testRejectsTamperedIterationCount() throws {
        try assertRejectedAfterFlippingByte(in: iterationRange)
    }

    func testRejectsTamperedSalt() throws {
        try assertRejectedAfterFlippingByte(in: saltRange)
    }

    func testRejectsTamperedNonce() throws {
        try assertRejectedAfterFlippingByte(in: nonceRange)
    }

    func testRejectsTamperedCiphertextBody() throws {
        let sealed = try makeContainer()
        try assertRejectedAfterFlippingByte(in: headerByteCount..<(sealed.count - tagByteCount))
    }

    func testRejectsTamperedTag() throws {
        let sealed = try makeContainer()
        try assertRejectedAfterFlippingByte(in: (sealed.count - tagByteCount)..<sealed.count)
    }

    func testRejectsTruncatedTag() throws {
        let sealed = try makeContainer()
        XCTAssertThrowsError(try IdentityCipher.open(sealed.dropLast(), passphrase: "accepted phrase placeholder"))
    }

    func testRejectsEmptyContainer() {
        XCTAssertThrowsError(try IdentityCipher.open(Data(), passphrase: "accepted phrase placeholder"))
    }

    func testRejectsEveryContainerShorterThanMinimumLength() {
        let minimumByteCount = headerByteCount + tagByteCount
        for length in 0..<minimumByteCount {
            XCTAssertThrowsError(
                try IdentityCipher.open(Data(repeating: 0, count: length), passphrase: "accepted phrase placeholder"),
                "Accepted truncated container of length \(length)"
            )
        }
    }

    func testRejectsBadMagic() {
        var container = Data(repeating: 0, count: headerByteCount + tagByteCount)
        container.replaceSubrange(magicRange, with: Data("NOTKID01".utf8))

        XCTAssertThrowsError(try IdentityCipher.open(container, passphrase: "accepted phrase placeholder"))
    }

    func testRejectsOversizedRandomInputWithoutCrashing() {
        var input = Data(count: 5 * 1_024 * 1_024)
        let randomStatus = input.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        XCTAssertEqual(randomStatus, errSecSuccess)

        XCTAssertThrowsError(try IdentityCipher.open(input, passphrase: "accepted phrase placeholder"))
    }

    private func makeContainer() throws -> Data {
        try IdentityCipher.seal(
            Data("ciphertext body placeholder".utf8),
            passphrase: "accepted phrase placeholder"
        )
    }

    private func assertRejectedAfterFlippingByte(in range: Range<Int>) throws {
        var tampered = try makeContainer()
        XCTAssertFalse(range.isEmpty)
        tampered[range.lowerBound] ^= 0x01

        XCTAssertThrowsError(try IdentityCipher.open(tampered, passphrase: "accepted phrase placeholder"))
    }
}
