import XCTest
@testable import KeyKeeperCore

final class CloudSyncNativeFenceTests: XCTestCase {
    func testTimeoutKeepsNativeOwnershipUntilActualCallback() async throws {
        let fence = CloudSyncNativeFence()
        let callbacks = CallbackBox()
        do {
            let _: Int = try await fence.perform(timeout: 0.01) { callbacks.callback = $0 }
            XCTFail("deadline must fail")
        } catch { XCTAssertEqual(error as? CloudSyncError, .unavailable) }
        do {
            let _: Int = try await fence.perform { _ in XCTFail("must not start second native request") }
            XCTFail("must remain busy")
        } catch { XCTAssertEqual(error as? CloudSyncError, .busy) }
        callbacks.callback?(.success(1))
        let value: Int = try await fence.perform { $0(.success(2)) }
        XCTAssertEqual(value, 2)
    }
    func testObservedAccountChangePreventsLocalEffectsAndLateResults() async throws {
        let fence = CloudSyncNativeFence()
        let binding = CloudSyncBinding(container: "test", environment: "Production", accountID: "synthetic")
        try fence.confirm(binding, permit: fence.capture())
        var effects = 0
        try fence.withBinding(binding) { effects += 1 }
        fence.invalidate()
        XCTAssertThrowsError(try fence.withBinding(binding) { effects += 1 })
        XCTAssertEqual(effects, 1)
        do {
            let _: Int = try await fence.perform { _ in XCTFail("invalidated fence must not start native work") }
            XCTFail("must fail")
        } catch { XCTAssertEqual(error as? CloudSyncError, .accountChanged) }
    }
}
private final class CallbackBox: @unchecked Sendable { var callback: ((Result<Int, Error>) -> Void)? }
