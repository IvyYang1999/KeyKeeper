import Foundation

/// Owns a native request even after the caller's deadline. Timeout never opens a second
/// request while the first is unresolved. Account changes share the local-effect lock.
final class CloudSyncNativeFence: @unchecked Sendable {
    struct Permit { fileprivate let generation: UInt64 }
    private let effects = NSRecursiveLock()
    private let operations = NSLock()
    private var invalidated = false
    private var generation: UInt64 = 0
    private var operation: (UUID, () -> Void)?
    private var confirmed: CloudSyncBinding?

    var hasOutstandingOperation: Bool { operations.withLock { operation != nil } }

    func capture() throws -> Permit {
        try effects.withLock {
            guard !invalidated else { throw CloudSyncError.accountChanged }
            return Permit(generation: generation)
        }
    }
    func withValid<T>(_ permit: Permit, _ effect: () throws -> T) throws -> T {
        try effects.withLock {
            guard !invalidated, permit.generation == generation else { throw CloudSyncError.accountChanged }
            return try effect()
        }
    }
    func confirm(_ binding: CloudSyncBinding, permit: Permit) throws {
        try withValid(permit) {
            if let confirmed, confirmed != binding { throw CloudSyncError.accountChanged }
            confirmed = binding
        }
    }
    func withBinding<T>(_ binding: CloudSyncBinding, _ effect: () throws -> T) throws -> T {
        try effects.withLock {
            guard !invalidated, confirmed == binding else { throw CloudSyncError.accountChanged }
            return try effect()
        }
    }
    func invalidate() {
        effects.withLock { invalidated = true; generation &+= 1 }
        let cancel = operations.withLock { operation?.1 }
        cancel?()
    }
    private func begin(_ permit: Permit, id: UUID, cancel: @escaping () -> Void, start: () -> Void) throws {
        try withValid(permit) {
            try operations.withLock {
                guard operation == nil else { throw CloudSyncError.busy }
                operation = (id, cancel)
            }
            start()
        }
    }
    private func finish(_ permit: Permit, id: UUID) -> Bool {
        let owned = operations.withLock {
            guard operation?.0 == id else { return false }
            operation = nil
            return true
        }
        return owned && ((try? withValid(permit) { true }) == true)
    }
    func perform<T>(timeout: TimeInterval = 35, cancel: @escaping () -> Void = {},
                    start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let permit = try capture(), id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let waiter = NativeWaiter(continuation)
            do {
                try begin(permit, id: id, cancel: cancel) {
                    start { result in
                        let valid = self.finish(permit, id: id)
                        waiter.finish(valid ? result : .failure(CloudSyncError.accountChanged))
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if waiter.finish(.failure(CloudSyncError.unavailable)) { cancel() }
                    // Only the real callback releases operation ownership.
                }
            } catch { waiter.finish(.failure(error)) }
        }
    }
}

private final class NativeWaiter<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<T, Error>) -> Bool {
        let saved = lock.withLock { let saved = continuation; continuation = nil; return saved }
        saved?.resume(with: result)
        return saved != nil
    }
}
