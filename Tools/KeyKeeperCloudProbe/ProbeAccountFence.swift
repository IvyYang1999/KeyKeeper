import Foundation

/// One invocation never resumes after an observed account change. Synchronous effects
/// linearize under this fence; async work must retain a permit and recheck it on completion.
final class ProbeAccountFence: @unchecked Sendable {
    struct Permit { fileprivate let epoch: UInt64 }
    private let effectLock = NSRecursiveLock()
    private var epoch: UInt64 = 0
    private var invalidated = false
    // No native API or file IO is called while holding this separate, short-lived lock.
    // The hard-deadline path therefore does not wait for an in-progress Keychain call.
    private let operationLock = NSLock()
    private var operation: (id: UUID, cancel: () -> Void)?

    func capture() throws -> Permit {
        try effectLock.withLock {
            guard !invalidated else { throw ProbeFailure.account }
            return Permit(epoch: epoch)
        }
    }

    func withValid<T>(_ permit: Permit, _ effect: () throws -> T) throws -> T {
        try effectLock.withLock {
            guard !invalidated, permit.epoch == epoch else { throw ProbeFailure.account }
            return try effect()
        }
    }

    func invalidate() {
        effectLock.withLock { invalidated = true; epoch &+= 1 }
        cancelCurrent()
    }

    func cancelCurrent() {
        let cancel = operationLock.withLock { operation?.cancel }
        cancel?()
    }

    func beginOperation(_ permit: Permit, id: UUID, cancel: @escaping () -> Void,
                        enqueue: () -> Void) throws {
        try withValid(permit) {
            try operationLock.withLock {
                guard operation == nil else { throw ProbeFailure.account }
                operation = (id, cancel)
            }
            // No check->add gap: account-change invalidation uses the same effect fence.
            enqueue()
        }
    }

    func finishOperation(_ permit: Permit, id: UUID) -> Bool {
        operationLock.withLock {
            if operation?.id == id { operation = nil }
        }
        return (try? withValid(permit) { true }) == true
    }
}
