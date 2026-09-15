import AppKit
import SwiftUI
import KeyKeeperCore

/// Manages a standalone floating window for authorization prompts.
@MainActor
final class AuthorizationWindowController {
    private(set) var window: NSWindow?
    private var windowDelegate: WindowCloseDelegate?
    private var isProgrammaticClose = false

    func show(request: AuthRequest,
              waiting: Int = 0,
              review: RequestReview? = nil,
              onAuthorize: @escaping (AuthorizationView.DurationChoice) throws -> Void,
              onDeny: @escaping () -> Void) {
        show(prompt: .strict(request), waiting: waiting, review: review, onAuthorize: onAuthorize, onDeny: onDeny)
    }

    func show(standing request: StandingApprovalRequest,
              review: RequestReview? = nil,
              onAuthorize: @escaping (AuthorizationView.DurationChoice) throws -> Void,
              onDeny: @escaping () -> Void) {
        show(prompt: .standing(request), waiting: 0, review: review, onAuthorize: onAuthorize, onDeny: onDeny)
    }

    func show(serviceRequest: IPCServer.PendingServiceRequest,
              waiting: Int = 0,
              review: RequestReview? = nil,
              onAuthorize: @escaping (AuthorizationView.DurationChoice) throws -> Void,
              onDeny: @escaping () -> Void) {
        show(prompt: .service(serviceRequest), waiting: waiting, review: review, onAuthorize: onAuthorize, onDeny: onDeny)
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
                      review: RequestReview?,
                      onAuthorize: @escaping (AuthorizationView.DurationChoice) throws -> Void,
                      onDeny: @escaping () -> Void) {
        // Close existing window if any
        dismiss()

        let view = AuthorizationView(
            prompt: prompt,
            onAuthorize: { [weak self] choice in
                try onAuthorize(choice)
                self?.dismiss()
            },
            onDeny: { [weak self] in
                onDeny()
                self?.dismiss()
            },
            review: review
        )

        // Frosted, title-less like a system prompt; the title stays for accessibility and
        // for the "N more waiting" count, shown small in the transparent bar. Hosted as the
        // full-frame container (not a content view controller) so glass runs under the title bar.
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
        Self.installContent(view, in: win)
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

    /// The root is full-window content, including the traffic-light padding. AppKit's
    /// automatic content-size animation adds title-bar height back while resizing it.
    /// One owner sizes the *frame* from the root's measured size, without that extra band.
    @discardableResult
    static func installContent<Content: View>(_ content: Content, in window: NSWindow) -> NSHostingView<AuthorizationWindowContent<Content>> {
        let hosting = NSHostingView(rootView: AuthorizationWindowContent(content: content) { [weak window] size in
            guard let window else { return }
            fit(window, to: size)
        })
        hosting.safeAreaRegions = []
        let initial = hosting.fittingSize
        // The measured root below now owns resizing, including shrinking. Leaving the
        // default min/max constraints enabled lets two independent owners resize the window.
        hosting.sizingOptions = []
        // A hosting view installed directly as contentView also participates in AppKit's
        // animated window sizing, even with sizing constraints disabled. Keep that bridge
        // out of this full-frame panel: the ordinary container only follows our frame size.
        let container = NSView(frame: NSRect(origin: .zero, size: initial))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        fit(window, to: initial)
        return hosting
    }

    private static func fit(_ window: NSWindow, to size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let size = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard window.frame.size != size else { return }
        var frame = window.frame
        frame.origin.y += frame.height - size.height // keep the top/title controls in place
        frame.size = size
        window.setFrame(frame, display: true, animate: false)
    }
}

struct AuthorizationWindowContent<Content: View>: View {
    let content: Content
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: true, vertical: true)
            .environment(\.authorizationPanelSizeChanged, onSizeChange)
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
