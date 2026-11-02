import Foundation

enum ProbeAccountFenceTests {
    static func run() throws {
        // The three effects share the same fence in production. A change arriving
        // after async verify but before the effect must cause zero new writes.
        for point in ["submit", "key-create", "confirm"] {
            let fence = ProbeAccountFence()
            let permit = try fence.capture()
            var writes = 0
            var pending = true
            fence.invalidate()
            do {
                if point == "submit" {
                    try fence.beginOperation(permit, id: UUID(), cancel: {}) { writes += 1 }
                } else {
                    try fence.withValid(permit) { writes += 1; pending = false }
                }
                throw ProbeFailure.corrupt
            } catch ProbeFailure.account { }
            guard writes == 0, pending else { throw ProbeFailure.corrupt }
        }

        let fence = ProbeAccountFence()
        let permit = try fence.capture(), operationID = UUID()
        var submissions = 0, cancellations = 0
        try fence.beginOperation(permit, id: operationID, cancel: { cancellations += 1 }) { submissions += 1 }
        fence.invalidate()
        guard submissions == 1, cancellations == 1,
              !fence.finishOperation(permit, id: operationID) else { throw ProbeFailure.corrupt }

        // A native Keychain call can hold the effect fence. The hard deadline's
        // cancellation path must remain independent of that potentially blocked call.
        let deadlineFence = ProbeAccountFence()
        let deadlinePermit = try deadlineFence.capture(), deadlineID = UUID()
        let cancelled = DispatchSemaphore(value: 0)
        try deadlineFence.beginOperation(deadlinePermit, id: deadlineID, cancel: { cancelled.signal() }) { }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? deadlineFence.withValid(deadlinePermit) {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            done.signal()
        }
        defer { release.signal() }
        guard entered.wait(timeout: .now() + 2) == .success else { throw ProbeFailure.corrupt }
        deadlineFence.cancelCurrent()
        guard cancelled.wait(timeout: .now() + 2) == .success else { throw ProbeFailure.corrupt }
        release.signal()
        guard done.wait(timeout: .now() + 2) == .success else { throw ProbeFailure.corrupt }
    }
}
