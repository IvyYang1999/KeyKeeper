import Foundation
import XCTest
@testable import KeyKeeperCLI

final class OutputRedactorTests: XCTestCase {
    private let replacement = Data("[REDACTED]".utf8)

    func testRedactsValueSplitAcrossDeterministicMatcherCalls() {
        let sample = "ABCDEF"
        var matcher = OutputRedactionMatcher(secrets: [sample])
        var output = Data()

        let firstOutput = matcher.process(Data("ABC".utf8))
        XCTAssertTrue(firstOutput.isEmpty)
        XCTAssertEqual(matcher.pendingByteCount, 3)
        output.append(firstOutput)

        let secondOutput = matcher.process(Data("DEF".utf8))
        XCTAssertEqual(secondOutput, replacement)
        XCTAssertEqual(matcher.pendingByteCount, 0)
        output.append(secondOutput)
        output.append(matcher.finish())

        assertRedacted(output, sample: sample, expected: replacement)
    }

    func testRedactsValueSplitAcrossFourDeterministicMatcherCalls() {
        let sample = "ABCDEF"
        var matcher = OutputRedactionMatcher(secrets: [sample])
        var output = Data()

        for chunk in ["A", "BC", "D", "EF"] {
            output.append(matcher.process(Data(chunk.utf8)))
        }
        output.append(matcher.finish())

        assertRedacted(output, sample: sample, expected: replacement)
    }

    func testEOFFlushMatchesCredentialHeldBehindLongerPrefix() {
        let sample = "ABCDEF"
        var matcher = OutputRedactionMatcher(secrets: ["ABCDEFGH", sample])

        let preEOFOutput = matcher.process(Data(sample.utf8))

        XCTAssertTrue(preEOFOutput.isEmpty)
        XCTAssertEqual(
            matcher.pendingByteCount,
            sample.utf8.count,
            "the complete credential must still be pending when EOF begins"
        )

        let eofOutput = matcher.finish()

        XCTAssertEqual(matcher.pendingByteCount, 0)
        assertRedacted(eofOutput, sample: sample, expected: replacement)
    }

    func testEOFFlushPreservesIncompleteCredentialPrefix() {
        let incompletePrefix = "ABC"
        var matcher = OutputRedactionMatcher(secrets: ["ABCDEFGH", "ABCDEF"])

        let preEOFOutput = matcher.process(Data(incompletePrefix.utf8))

        XCTAssertTrue(preEOFOutput.isEmpty)
        XCTAssertEqual(matcher.pendingByteCount, incompletePrefix.utf8.count)
        XCTAssertEqual(matcher.finish(), Data(incompletePrefix.utf8))
        XCTAssertEqual(matcher.pendingByteCount, 0)
    }

    func testRedactsAdjacentOccurrences() {
        let sample = "ABCDEF"
        let output = runMatcher(
            values: [sample],
            chunks: ["ABCDEFABC", "DEF"]
        )

        var expected = replacement
        expected.append(replacement)
        assertRedacted(output, sample: sample, expected: expected)
    }

    func testRedactsOverlappingOccurrencesWithoutLeavingCredential() {
        let sample = "ABA"
        let output = runMatcher(values: [sample], chunks: ["ABABA"])

        var expected = replacement
        expected.append(Data("BA".utf8))
        assertRedacted(output, sample: sample, expected: expected)
    }

    func testLongestCredentialWinsForSharedPrefixAndSuffixPatterns() {
        let longest = "ABCDEF"
        let output = runMatcher(
            values: ["ABC", "DEF", longest, "CDE"],
            chunks: ["AB", "CD", "EF"]
        )

        assertRedacted(output, sample: longest, expected: replacement)
        XCTAssertNil(output.range(of: Data("ABC".utf8)))
        XCTAssertNil(output.range(of: Data("DEF".utf8)))
    }

    func testPreservedBytesAroundReplacementDoNotReassembleCredential() {
        let sample = "ABCDEF"
        let output = runMatcher(
            values: [sample],
            chunks: ["ABCABC", "DEFDEF"]
        )

        var expected = Data("ABC".utf8)
        expected.append(replacement)
        expected.append(Data("DEF".utf8))
        assertRedacted(output, sample: sample, expected: expected)
    }

    func testReplacementBoundaryCannotReassembleCredential() {
        let sample = "D]XY9Q"
        let output = runMatcher(
            values: [sample],
            chunks: [sample, "XY9Q"]
        )

        XCTAssertNotNil(output.range(of: replacement))
        XCTAssertNil(
            output.range(of: Data(sample.utf8)),
            "replacement bytes and preserved bytes reassembled the credential"
        )
    }

    func testPreservedBytesBeforeReplacementCannotReassembleCredential() {
        let sample = "XY9Q[R"
        let output = runMatcher(
            values: [sample],
            chunks: ["XY9Q", sample]
        )

        XCTAssertNotNil(output.range(of: replacement))
        XCTAssertNil(
            output.range(of: Data(sample.utf8)),
            "preserved bytes and the replacement prefix reassembled the credential"
        )
    }

    func testCredentialContainedInStandardMarkerUsesSafeAlternative() {
        let sample = "REDACT"
        let output = runMatcher(values: [sample], chunks: [sample])

        XCTAssertEqual(output, Data("[FILTERED]".utf8))
        XCTAssertNil(output.range(of: Data(sample.utf8)))
    }

    func testRedactsValueBytesInsideInvalidUTF8Chunk() {
        let sample = "FAKEVALUE1234"
        var invalidUTF8 = Data([0xFF])
        invalidUTF8.append(Data(sample.utf8))
        invalidUTF8.append(0xFE)

        var matcher = OutputRedactionMatcher(secrets: [sample])
        var output = matcher.process(invalidUTF8)
        output.append(matcher.finish())

        var expected = Data([0xFF])
        expected.append(replacement)
        expected.append(0xFE)
        assertRedacted(output, sample: sample, expected: expected)
    }

    func testEmptyCredentialsAreIgnoredAndBytesPassThrough() {
        let input = Data("XY9Q".utf8)
        var matcher = OutputRedactionMatcher(secrets: [""])

        XCTAssertEqual(matcher.process(input), input)
        XCTAssertEqual(matcher.pendingByteCount, 0)
        XCTAssertTrue(matcher.finish().isEmpty)
    }

    func testStderrPathRedactsOutput() throws {
        let sample = "XY9Q"
        let input = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let redactor = OutputRedactor(
            secrets: [sample],
            stdout: stdout.fileHandleForWriting,
            stderr: stderr.fileHandleForWriting
        )

        redactor.startReading(pipe: input, target: .stderr)
        input.fileHandleForWriting.write(Data(sample.utf8))
        try input.fileHandleForWriting.close()
        redactor.waitUntilDone()
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()

        let stdoutOutput = try stdout.fileHandleForReading.readToEnd() ?? Data()
        let stderrOutput = try XCTUnwrap(stderr.fileHandleForReading.readToEnd())
        XCTAssertTrue(stdoutOutput.isEmpty)
        assertRedacted(stderrOutput, sample: sample, expected: replacement)
    }

    private func runMatcher(values: [String], chunks: [String]) -> Data {
        var matcher = OutputRedactionMatcher(secrets: values)
        var output = Data()
        for chunk in chunks {
            output.append(matcher.process(Data(chunk.utf8)))
        }
        output.append(matcher.finish())
        return output
    }

    private func assertRedacted(
        _ output: Data,
        sample: String,
        expected: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(
            output.range(of: Data(sample.utf8)),
            "output contains unredacted sample bytes",
            file: file,
            line: line
        )
        XCTAssertEqual(output, expected, file: file, line: line)
    }
}
