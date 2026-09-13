import Foundation
import LocalAuthentication

/// Proof that the person is at the Mac, for decisions that widen what KeyKeeper trusts.
enum DeviceOwnerCheck {
    static func confirm(reason: String, reply: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        // No way to ask (an unsigned development build, no password set): the answer is no. Trusting
        // a file somebody else wrote is not something a click alone should do.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            DispatchQueue.main.async { reply(false) }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { approved, _ in
            DispatchQueue.main.async { reply(approved) }
        }
    }
}
