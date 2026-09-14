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
              onAuthorize: @escaping (ApprovalDuration) throws -> Void,
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
              onAuthorize: @escaping (ApprovalDuration) throws -> Void,
              onDeny: @escaping () -> Void) {
        show(
            prompt: .service(serviceRequest),
            waiting: waiting,
            onAuthorizeGrant: nil,
            onAuthorizeService: onAuthorize,
            onDeny: onDeny
        )
    }

    /// Keeps the "(N more waiting)" suffix current while the window is open; requests
    /// that arrive after the prompt was shown used to be invisible until the next prompt.
    func updateWaiting(_ waiting: Int) {
        window?.title = Self.windowTitle(waiting: waiting)
        window?.titleVisibility = waiting > 0 ? .visible : .hidden
    }

    /// Used by the menu bar's "Allow…": choosing a duration (and Touch ID for strict keys)
    /// still happens in this window.
    func bringToFront() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        waiting > 0 ? L("KeyKeeper Authorization (\(waiting) more waiting)") : L("KeyKeeper Authorization")
    }

    private func show(prompt: AuthorizationPrompt,
                      waiting: Int,
                      onAuthorizeGrant: ((ApprovalDuration) throws -> Void)?,
                      onAuthorizeService: ((ApprovalDuration) throws -> Void)?,
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

        // Frosted, title-less like a system prompt; the title stays for accessibility and
        // for the "N more waiting" count, shown small in the transparent bar. Hosted as the
        // content view (not a content view controller) so the glass runs under the title bar.
        // Same order as the trust prompt panel: make the title bar transparent before the
        // SwiftUI content is installed, or the content keeps an opaque-bar safe area and the
        // traffic lights end up floating over a clear strip.
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = Self.windowTitle(waiting: waiting)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = waiting > 0 ? .visible : .hidden
        win.isMovableByWindowBackground = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        // Let the SwiftUI content (and its glass) fill the whole frame, under the title bar;
        // the view keeps its own top padding for the traffic lights.
        hosting.safeAreaRegions = []
        win.contentView = hosting
        win.setContentSize(hosting.fittingSize)
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
