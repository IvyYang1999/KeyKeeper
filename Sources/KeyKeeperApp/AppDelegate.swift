import AppKit
import SwiftUI
import Combine
import KeyKeeperCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var ipcServer: IPCServer!
    private let credentialService = KeychainCredentialService()
    private var authWindowController: AuthorizationWindowController!
    private var cancellables = Set<AnyCancellable>()
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var isTerminating = false
    private let updateController = UpdateController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        installTerminationSignalHandlers()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon. UI automation (E2E acceptance) can only address regular apps,
        // so a test-only environment variable keeps the Dock icon; nothing else changes.
        if ProcessInfo.processInfo.environment["KEYKEEPER_UI_TEST_REGULAR"] == nil {
            NSApp.setActivationPolicy(.accessory)
        }

        // Acquire the IPC endpoint before creating UI. A healthy listener means this launch is a duplicate.
        ipcServer = IPCServer(session: credentialService)
        switch ipcServer.start() {
        case .started(let disposition):
            if disposition == .replacedStaleSocket {
                writeToStandardError("KeyKeeper replaced a stale IPC socket")
            }
        case .anotherInstanceRunning:
            writeToStandardError("another KeyKeeper instance is running")
            terminateGracefully()
            return
        case .failed(let error):
            writeToStandardError("KeyKeeper IPC startup failed: \(error.localizedDescription)")
            terminateGracefully()
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "KeyKeeper")
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.contentSize = DS.Popover.size
        popover.behavior = .semitransient
        // Dragging the popover away turns it into a window that survives clicks elsewhere,
        // which is what you want while pasting several keys.
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MainView(session: credentialService, updateController: updateController)
        )

        authWindowController = AuthorizationWindowController()

        // Watch for pending authorization requests
        ipcServer.$pendingRequest
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                self?.handleAuthRequest(pending)
            }
            .store(in: &cancellables)

        ipcServer.$pendingServiceRequest
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                self?.handleServiceRequest(pending)
            }
            .store(in: &cancellables)

        ipcServer.$waitingCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] waiting in
                self?.authWindowController.updateWaiting(waiting)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(ipcServer.$pendingRequest, ipcServer.$pendingServiceRequest)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] authRequest, serviceRequest in
                if authRequest == nil, serviceRequest == nil {
                    self?.authWindowController.dismiss()
                }
            }
            .store(in: &cancellables)

        // Open the popover only on first run. A CLI request from cron or a script also
        // launches the app, and must not pop a window onto the user's screen.
        if ProcessInfo.processInfo.environment["KEYKEEPER_UI_TEST_SETTINGS"] == "1" {
            UICommandInbox.shared.requestSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showPopover()
            }
        } else if Self.shouldShowPopoverOnLaunch(
            setupComplete: UserDefaults.standard.bool(forKey: "setupComplete")
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showPopover()
            }
        }
    }

    /// `keykeeper://` links registered in Info.plist (CFBundleURLTypes).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let link = DeepLink.parse(url) else { continue }
            UICommandInbox.shared.requestAddCredential(link)
        }
        if !popover.isShown { showPopover() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        ipcServer?.stop()
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources.removeAll()
    }

    private func handleAuthRequest(_ pending: IPCServer.PendingAuthRequest) {
        let request = pending.request
        let grantStore = GrantStore.default

        authWindowController.show(
            request: request,
            waiting: ipcServer.waitingCount,
            onAuthorize: { [weak self] duration in
                guard let self else { return }

                // Errors propagate to the window, which shows them and stays open so the
                // user can pick another option; the CLI keeps waiting on the same request.
                let resolvedDuration = try GrantAuthorizationPolicy.resolveIssuedDuration(
                    requestedDuration: duration,
                    requestSessionId: request.sessionId
                )
                let grant = Grant(
                    credentialId: request.credentialId,
                    sessionId: request.sessionId,
                    duration: resolvedDuration
                )
                try grantStore.addGrant(grant)
                let response = AuthResponse(granted: true, grantId: grant.id)
                self.ipcServer.respond(to: pending, with: response)
            },
            onDeny: { [weak self] in
                self?.ipcServer.respond(
                    to: pending,
                    with: AuthResponse(granted: false, error: "User denied")
                )
            }
        )
    }

    private func handleServiceRequest(_ pending: IPCServer.PendingServiceRequest) {
        let serviceGrantStore = ServiceGrantStore.default

        authWindowController.show(
            serviceRequest: pending,
            waiting: ipcServer.waitingCount,
            onAuthorize: { [weak self] duration in
                guard let self else { return }

                let grant = ServiceGrant(
                    credentialId: pending.credentialId,
                    subjectFingerprint: pending.callerIdentity.subjectFingerprint,
                    subjectDisplayName: pending.callerIdentity.displayName,
                    fields: pending.fieldNames,
                    duration: duration
                )
                try serviceGrantStore.addGrant(grant)
                self.ipcServer.fulfillServiceRequest(pending, serviceGrant: grant)
            },
            onDeny: { [weak self] in
                self?.ipcServer.denyServiceRequest(pending)
            }
        )
    }

    static func shouldShowPopoverOnLaunch(setupComplete: Bool) -> Bool {
        !setupComplete
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        activatePopover()
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            activatePopover()
        }
    }

    // MARK: - Status bar menu (right-click)

    private func showStatusMenu() {
        let menu = StatusMenuBuilder.build(
            launchAtLogin: LoginItemManager.isEnabled,
            launchAtLoginAvailable: LoginItemManager.isAvailable,
            target: self,
            actions: StatusMenuBuilder.Actions(
                open: #selector(menuOpen),
                checkForUpdates: #selector(menuCheckForUpdates),
                launchAtLogin: #selector(menuToggleLaunchAtLogin),
                settings: #selector(menuSettings),
                quit: #selector(menuQuit)
            )
        )
        // Assigning the menu makes the next click open it; clearing it afterwards keeps
        // left-click bound to the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpen() {
        if !popover.isShown { showPopover() }
    }

    @objc private func menuCheckForUpdates() {
        updateController.checkForUpdates()
    }

    @objc private func menuToggleLaunchAtLogin() {
        do {
            try LoginItemManager.setEnabled(!LoginItemManager.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription + "\n\nYou can also add KeyKeeper under System Settings › General › Login Items."
            alert.runModal()
        }
    }

    @objc private func menuSettings() {
        UICommandInbox.shared.requestSettings()
        if !popover.isShown { showPopover() }
    }

    /// Quitting is cheap now: the app relaunches automatically the next time the CLI
    /// requests a value, and the keychain needs no unlocking. No confirmation needed.
    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    /// Ensure the popover window accepts keyboard input.
    /// Without this, TextFields inside the popover won't receive key events
    /// when using inline views instead of sheets.
    private func activatePopover() {
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.terminateGracefully()
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    private func terminateGracefully() {
        guard !isTerminating else { return }
        isTerminating = true
        ipcServer?.stop()
        NSApp.terminate(nil)
    }

    private func writeToStandardError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        true
    }
}
