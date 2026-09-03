import XCTest
@testable import KeyKeeperCore

final class EnvironmentVariableNameTests: XCTestCase {
    func test字段名转环境变量名规则() {
        XCTAssertEqual(EnvironmentVariableName.from(fieldName: "api-key"), "API_KEY")
        XCTAssertEqual(EnvironmentVariableName.from(fieldName: "base url"), "BASE_URL")
        XCTAssertEqual(EnvironmentVariableName.from(fieldName: "apiKey"), "APIKEY")
        XCTAssertEqual(EnvironmentVariableName.from(fieldName: "__weird--name__"), "WEIRD_NAME")
        XCTAssertEqual(EnvironmentVariableName.from(fieldName: "token", prefix: "STRIPE_"), "STRIPE_TOKEN")
    }
}
