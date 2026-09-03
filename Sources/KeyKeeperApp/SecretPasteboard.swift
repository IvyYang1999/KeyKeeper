import AppKit

/// Clipboard handling for secret values: marks them as concealed so clipboard
/// managers skip them, and clears them again after a short delay unless the user
/// has copied something else in the meantime.
enum SecretPasteboard {
    static let clearDelay: TimeInterval = 30
    /// Recognised by clipboard history tools (Paste, Maccy, Alfred, 1Password…) as "do not record".
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Writes the secret and returns the pasteboard change count identifying this write.
    @discardableResult
    static func write(_ secret: String, to pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType], owner: nil)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString("", forType: concealedType)
        return pasteboard.changeCount
    }

    /// Clears the pasteboard only if it still holds the write identified by `changeCount`.
    @discardableResult
    static func clearIfUnchanged(since changeCount: Int, pasteboard: NSPasteboard = .general) -> Bool {
        guard shouldClear(currentChangeCount: pasteboard.changeCount, expectedChangeCount: changeCount) else {
            return false
        }
        pasteboard.clearContents()
        return true
    }

    static func shouldClear(currentChangeCount: Int, expectedChangeCount: Int) -> Bool {
        currentChangeCount == expectedChangeCount
    }

    static func scheduleClear(after changeCount: Int, pasteboard: NSPasteboard = .general) {
        DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay) {
            clearIfUnchanged(since: changeCount, pasteboard: pasteboard)
        }
    }
}
