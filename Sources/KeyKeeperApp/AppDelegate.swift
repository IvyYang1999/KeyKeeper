import AppKit
import SwiftUI
import Combine
import KeyKeeperCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var ipcServer: IPCServer!
    private let sessionManager = SessionManager(lockPolicy: .untilManualOrReboot)
    private lazy var sessionState = SessionStateViewModel(session: sessionManager)
    private var authWindowController: AuthorizationWindowController!
    private var cancellables = Set<AnyCancellable>()
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var isTerminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        installTerminationSignalHandlers()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Acquire the IPC endpoint before creating UI. A healthy listener means this launch is a duplicate.
        ipcServer = IPCServer(session: sessionManager)
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
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItemIcon(for: sessionState.bannerState)
        sessionState.$bannerState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusItemIcon(for: state)
            }
            .store(in: &cancellables)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 480)
        popover.behavior = .semitransient
        popover.contentViewController = NSHostingController(
            rootView: MainView(session: sessionManager, sessionState: sessionState)
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

        Publishers.CombineLatest(ipcServer.$pendingRequest, ipcServer.$pendingServiceRequest)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] authRequest, serviceRequest in
                if authRequest == nil, serviceRequest == nil {
                    self?.authWindowController.dismiss()
                }
            }
            .store(in: &cancellables)

        // Open the popover only when the user has something to do in it (first run, or no
        // vault yet). A CLI `keykeeper unlock` from cron or a script also launches the app,
        // and must not pop a window onto the screen.
        if Self.shouldShowPopoverOnLaunch(
            setupComplete: UserDefaults.standard.bool(forKey: "setupComplete"),
            sessionState: sessionState.bannerState
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
            NotificationCenter.default.post(
                name: .keyKeeperOpenAddCredential,
                object: DeepLinkPayload(link: link)
            )
        }
        if !popover.isShown { showPopover() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        sessionManager.lock()
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

    static func shouldShowPopoverOnLaunch(setupComplete: Bool, sessionState: SessionBannerState) -> Bool {
        !setupComplete || sessionState == .needsVault
    }

    /// The menu bar icon is the only always-visible signal that background jobs will fail.
    static func statusItemSymbol(for state: SessionBannerState) -> (name: String, description: String) {
        switch state {
        case .unlocked:
            return ("key.fill", "KeyKeeper, vault unlocked")
        case .locked:
            return ("lock.fill", "KeyKeeper, vault locked")
        case .needsVault:
            return ("lock.slash", "KeyKeeper, no vault yet")
        }
    }

    private func updateStatusItemIcon(for state: SessionBannerState) {
        guard let button = statusItem?.button else { return }
        let symbol = Self.statusItemSymbol(for: state)
        button.image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: symbol.description)
        button.toolTip = symbol.description
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
            state: sessionState.bannerState,
            launchAtLogin: LoginItemManager.isEnabled,
            launchAtLoginAvailable: LoginItemManager.isAvailable,
            target: self,
            actions: StatusMenuBuilder.Actions(
                open: #selector(menuOpen),
                lock: #selector(menuLock),
                unlock: #selector(menuUnlock),
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

    @objc private func menuLock() {
        sessionState.lock()
    }

    /// Unlock and vault creation both live in the banner at the top of the popover.
    @objc private func menuUnlock() {
        if !popover.isShown { showPopover() }
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
        NotificationCenter.default.post(name: .keyKeeperOpenSettings, object: nil)
        if !popover.isShown { showPopover() }
    }

    @objc private func menuQuit() {
        guard sessionState.isUnlocked else {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Quit KeyKeeper?"
        alert.informativeText = "Quitting locks the vault. Cron jobs, scripts and AI tools can't read keys until you open KeyKeeper and unlock it again."
        alert.addButton(withTitle: "Quit and Lock Vault")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
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
