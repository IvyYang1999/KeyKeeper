import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class CredentialPresentationTests: XCTestCase {
    /// yyt 2026-09-11：文件类的 key 要一眼看出是文件，不然会以为是 bug。
    func test按字段判断是文件还是文本() {
        func credential(_ fields: [String: CredentialField]) -> Credential {
            Credential(label: "X", notes: "", links: [], fields: fields, security: .standard, created: "2026-09-11", updated: "2026-09-11")
        }
        XCTAssertEqual(CredentialKind(credential(["api-key": .init(secret: true)])), .text)
        XCTAssertEqual(CredentialKind(credential(["credentials-json": .init(secret: true, fileFormat: .serviceAccountJSON)])), .serviceAccountFile)
    }
}
