import AppKit
import SwiftUI
import Combine
import KeyKeeperCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var ipcServer: IPCServer!
    private var authWindowController: AuthorizationWindowController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "KeyKeeper")
            button.action = #selector(togglePopover)
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 480)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MainView())

        // Start IPC server for CLI authorization requests
        ipcServer = IPCServer()
        authWindowController = AuthorizationWindowController()
        ipcServer.start()

        // Watch for pending authorization requests
        ipcServer.$pendingRequest
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                self?.handleAuthRequest(pending)
            }
            .store(in: &cancellables)

        // Auto-show popover on launch so user knows the app is running
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showPopover()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcServer.stop()
    }

    private func handleAuthRequest(_ pending: IPCServer.PendingAuthRequest) {
        let request = pending.request
        let grantStore = GrantStore.default

        authWindowController.show(
            request: request,
            onAuthorize: { [weak self] duration in
                guard let self else { return }

                // Resolve actual duration (fill in session ID for .session)
                let resolvedDuration: GrantDuration
                if case .session = duration {
                    resolvedDuration = .session(request.sessionId ?? UUID().uuidString)
                } else {
                    resolvedDuration = duration
                }

                let grant = Grant(
                    credentialId: request.credentialId,
                    sessionId: request.sessionId,
                    duration: resolvedDuration
                )

                do {
                    try grantStore.addGrant(grant)
                    let response = AuthResponse(granted: true, grantId: grant.id)
                    self.ipcServer.respond(to: pending, with: response)
                } catch {
                    let response = AuthResponse(granted: false, error: error.localizedDescription)
                    self.ipcServer.respond(to: pending, with: response)
                }
            },
            onDeny: { [weak self] in
                self?.ipcServer.respond(
                    to: pending,
                    with: AuthResponse(granted: false, error: "User denied")
                )
            }
        )
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
