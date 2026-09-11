import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class PythonSourceExtractorTests: XCTestCase {
    func testLiteralAndEnvironmentDefaultsNeverEvaluateSource() throws {
        for expression in ["'synthetic-value'", "os.getenv('ADMIN_KEY', 'synthetic-value')", "os.environ.get('OTHER_NAME', 'synthetic-value')"] {
            let input = "raise RuntimeError('must not execute')\nADMIN_KEY = " + expression
            XCTAssertEqual(try PythonSourceExtractor.extract(Data(input.utf8), symbol: "ADMIN_KEY"), "synthetic-value")
        }
        XCTAssertEqual(try PythonSourceExtractor.extract(Data("ADMIN_KEY: str = 'a\\n\\u4e2d\\x21'".utf8), symbol: "ADMIN_KEY"), "a\n中!")
    }
    func testCommentsDocstringsDynamicExpressionsAndAmbiguityFailClosed() {
        for input in ["# ADMIN_KEY = 'fake'", "\"\"\"ADMIN_KEY = 'fake'\"\"\"",
            "def f():\n  ADMIN_KEY = 'nested'", "ADMIN_KEY = produce()", "ADMIN_KEY = 'a' + 'b'",
            "ADMIN_KEY = f'value-{42}'", "ADMIN_KEY = b'bytes'", "ADMIN_KEY = ''",
            "ADMIN_KEY = 'a'\nADMIN_KEY = 'b'", "ADMIN_KEY = 'a'\nif True:\n ADMIN_KEY = 'b'",
            "ADMIN_KEY = os.getenv('ADMIN_KEY', default='a')", "ADMIN_KEY = other.getenv('x', 'a')",
            "ADMIN_KEY = 'a'\ndel ADMIN_KEY", "ADMIN_KEY = 'a'\ndef ADMIN_KEY(): pass",
            "ADMIN_KEY = 'unterminated"] {
            XCTAssertThrowsError(try PythonSourceExtractor.extract(Data(input.utf8), symbol: "ADMIN_KEY")) { error in
                XCTAssertEqual(error as? ClipboardSaveError, .unsupportedSource)
            }
        }
    }
    func testPrivatePipesHandleLargeSourceAndBoundOutput() throws {
        let large = String(repeating: "# synthetic padding\n", count: 40_000) + "ADMIN_KEY='synthetic-value'"
        XCTAssertEqual(try PythonSourceExtractor.extract(Data(large.utf8), symbol: "ADMIN_KEY"), "synthetic-value")
        let atLimit = "X='" + String(repeating: "a", count: 65_536) + "'"
        XCTAssertEqual(try PythonSourceExtractor.extract(Data(atLimit.utf8), symbol: "X").utf8.count, 65_536)
        for literal in [String(repeating: "a", count: 65_537), "\\x00", "   "] {
            XCTAssertThrowsError(try PythonSourceExtractor.extract(Data("X='\(literal)'".utf8), symbol: "X"))
        }
        XCTAssertThrowsError(try PythonSourceExtractor.extract(Data([0xff, 0xfe]), symbol: "X"))
    }

    func testBoundsAndPrivateProcessTimeout() throws {
        XCTAssertThrowsError(try PythonSourceExtractor.extract(Data(repeating: 32, count: 1_048_577), symbol: "ADMIN_KEY"))
        XCTAssertThrowsError(try PythonSourceExtractor.extract(Data("X='a'".utf8), symbol: "X;print(1)"))
        let begin = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try PythonSourceExtractor.run(executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"], input: Data(), timeout: 0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 1)
    }
}
