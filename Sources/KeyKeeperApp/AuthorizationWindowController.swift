import AppKit
import SwiftUI
import KeyKeeperCore

/// Manages a standalone floating window for authorization prompts.
@MainActor
final class AuthorizationWindowController {
    private var window: NSWindow?
    private var windowDelegate: WindowCloseDelegate?
    private var isProgrammaticClose = false

    func show(request: AuthRequest,
              waiting: Int = 0,
              onAuthorize: @escaping (GrantDuration) throws -> Void,
              onDeny: @escaping () -> Void) {
        show(
            prompt: .strict(request),
            waiting: waiting,
            onAuthorizeGrant: onAuthorize,
            onAuthorizeService: nil,
            onDeny: onDeny
        )
    }

    func show(serviceRequest: IPCServer.PendingServiceRequest,
              waiting: Int = 0,
              onAuthorize: @escaping (ServiceGrantDuration) throws -> Void,
              onDeny: @escaping () -> Void) {
        show(
            prompt: .service(serviceRequest),
            waiting: waiting,
            onAuthorizeGrant: nil,
            onAuthorizeService: onAuthorize,
            onDeny: onDeny
        )
    }

    func dismiss() {
        guard let window else { return }
        isProgrammaticClose = true
        window.close()
        isProgrammaticClose = false
        self.window = nil
        windowDelegate = nil
    }

    static func windowTitle(waiting: Int) -> String {
        waiting > 0 ? "KeyKeeper Authorization (\(waiting) more waiting)" : "KeyKeeper Authorization"
    }

    private func show(prompt: AuthorizationPrompt,
                      waiting: Int,
                      onAuthorizeGrant: ((GrantDuration) throws -> Void)?,
                      onAuthorizeService: ((ServiceGrantDuration) throws -> Void)?,
                      onDeny: @escaping () -> Void) {
        // Close existing window if any
        dismiss()

        let view = AuthorizationView(
            prompt: prompt,
            onAuthorizeGrant: { [weak self] duration in
                try onAuthorizeGrant?(duration)
                self?.dismiss()
            },
            onAuthorizeService: { [weak self] duration in
                try onAuthorizeService?(duration)
                self?.dismiss()
            },
            onDeny: { [weak self] in
                onDeny()
                self?.dismiss()
            }
        )

        let hostingController = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: hostingController)
        win.title = Self.windowTitle(waiting: waiting)
        win.styleMask = [.titled, .closable]
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.center()

        // Keep a strong reference to the delegate
        let delegate = WindowCloseDelegate(onClose: { [weak self] in
            guard let self else { return }
            guard !self.isProgrammaticClose else { return }
            onDeny()
            self.window = nil
            self.windowDelegate = nil
        })
        windowDelegate = delegate
        win.delegate = delegate

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
