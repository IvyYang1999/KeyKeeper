import AppKit
import SwiftUI
import KeyKeeperCore

/// Manages a standalone floating window for authorization prompts.
@MainActor
final class AuthorizationWindowController {
    private var window: NSWindow?
    private var windowDelegate: WindowCloseDelegate?

    func show(request: AuthRequest,
              onAuthorize: @escaping (GrantDuration) -> Void,
              onDeny: @escaping () -> Void) {
        // Close existing window if any
        dismiss()

        let view = AuthorizationView(
            request: request,
            onAuthorize: { [weak self] duration in
                onAuthorize(duration)
                self?.dismiss()
            },
            onDeny: { [weak self] in
                onDeny()
                self?.dismiss()
            }
        )

        let hostingController = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: hostingController)
        win.title = "KeyKeeper Authorization"
        win.styleMask = [.titled, .closable]
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.center()

        // Keep a strong reference to the delegate
        let delegate = WindowCloseDelegate(onClose: { [weak self] in
            onDeny()
            self?.window = nil
            self?.windowDelegate = nil
        })
        windowDelegate = delegate
        win.delegate = delegate

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
        window = nil
        windowDelegate = nil
    }
}

/// Detects when user closes the authorization window via the red button.
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
