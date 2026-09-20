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
    private let browserSessions = BrowserSessionFeature()
    private var mainWindow: MainWindowController!

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
        StandingApprovalRequester.shared.handler = { [weak self] request in self?.handleStandingApproval(request) }
        let browserImportProposalStore: BrowserImportProposalStore
        do {
            browserImportProposalStore = try .production()
        } catch {
            writeToStandardError("KeyKeeper browser import storage setup failed: \(error.localizedDescription)")
            terminateGracefully()
            return
        }
        ipcServer = IPCServer(session: credentialService, approvals: .shared,
            clipboardSaveController: ClipboardSaveController(service: credentialService, approvals: .shared),
            envImportController: EnvImportController(service: credentialService, approvals: .shared),
            browserSessionController: browserSessions.controller,
            browserImportProposalStore: browserImportProposalStore)
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

        // After the duplicate check: a second instance is about to quit and must not touch the files.
        LaunchMaintenance.run(.init(meta: MetaStore.default, inventory: credentialService.inspectValueInventory,
                                    approvals: .shared, directory: KeyKeeperPaths.applicationSupportDirectory,
                                    sessionStore: browserSessions.store))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "KeyKeeper")
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        mainWindow = MainWindowController { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(MainWindowView(
                router: .shared,
                updateController: self.updateController,
                session: self.credentialService,
                browserSessions: self.browserSessions.controller,
                importFile: { [weak self] request, completion in
                    guard let self else { completion(.init(success: false, errorCode: .storageUnavailable)); return }
                    self.ipcServer.importFile(request, completion: completion)
                },
                onShowSetup: { [weak self] in
                    UserDefaults.standard.set(false, forKey: "setupComplete")
                    self?.showPopover()
                }
            ))
        }

        popover = NSPopover()
        popover.contentSize = DS.Popover.size
        popover.behavior = .semitransient
        // Dragging the popover away turns it into a window that survives clicks elsewhere,
        // which is what you want while pasting several keys.
        popover.delegate = self
        let popoverContent = NSHostingController(
            rootView: MainView(session: credentialService,
                importFile: { [weak self] request, completion in
                    guard let self else { completion(.init(success: false, errorCode: .storageUnavailable)); return }
                    self.ipcServer.importFile(request, completion: completion)
                },
                openMainWindow: { [weak self] section, credentialId in
                    self?.showMainWindow(section: section, credentialId: credentialId)
                },
                reopenPopover: { [weak self] in
                    guard let self, !self.popover.isShown else { return }
                    self.showPopover()
                })
        )
        // The home page is as tall as its content; the add page keeps the fixed size.
        popoverContent.sizingOptions = [.preferredContentSize]
        popover.contentViewController = popoverContent

        // The status item shows how many requests are waiting, so they are visible even
        // when the floating prompt is behind another window.
        Publishers.CombineLatest(ApprovalCenter.shared.$items, ApprovalCenter.shared.$missed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items, missed in self?.updateStatusBadge(count: items.count + missed.count) }
            .store(in: &cancellables)

        ApprovalCenter.shared.refreshMissed()
        NotificationCenter.default.publisher(for: .authorizationMissed)
            .receive(on: DispatchQueue.main)
            .sink { _ in ApprovalCenter.shared.refreshMissed() }
            .store(in: &cancellables)

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
                    self?.clearAuthApproval()
                }
            }
            .store(in: &cancellables)

        // Open the popover only on first run. A CLI request from cron or a script also
        // launches the app, and must not pop a window onto the user's screen.
        if ProcessInfo.processInfo.environment["KEYKEEPER_UI_TEST_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showMainWindow(section: .settings)
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
        var wantsPopover = false
        for url in urls {
            switch DeepLink.parse(url) {
            case .openWindow(let section, let credentialId):
                showMainWindow(section: section.flatMap(MainWindowRouter.Section.init(rawValue:)) ?? (credentialId == nil ? nil : .keys),
                               credentialId: credentialId)
            case .some(let link):
                UICommandInbox.shared.requestAddCredential(link)
                wantsPopover = true
            case nil:
                wantsPopover = true
            }
        }
        if wantsPopover, !popover.isShown { showPopover() }
    }

    /// The Dock icon (while the main window is open) or a relaunch from Finder opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func showMainWindow(section: MainWindowRouter.Section? = nil, credentialId: String? = nil) {
        if popover?.isShown == true { popover.performClose(nil) }
        mainWindow?.show(section: section, credentialId: credentialId)
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        ipcServer?.stop()
        if TestInstance.cleansUpOnQuit { TestInstance.cleanUpKeychain() }
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources.removeAll()
    }

    private var authApprovalID: UUID?

    private func registerAuthApproval(title: String, detail: String, deny: @escaping () -> Void) {
        clearAuthApproval()
        let id = UUID()
        authApprovalID = id
        ApprovalCenter.shared.add(.init(
            id: id, symbol: "key.fill", title: title, detail: detail, expiresAt: nil,
            confirmTitle: L("Allow"), destructive: false, opensWindow: true,
            confirm: { [weak self] in self?.authWindowController.bringToFront() },
            deny: deny
        ))
    }

    private func clearAuthApproval() {
        if let authApprovalID { ApprovalCenter.shared.remove(id: authApprovalID) }
        authApprovalID = nil
    }

    private func updateStatusBadge(count: Int) {
        guard let button = statusItem?.button else { return }
        button.imagePosition = .imageLeft
        button.title = count > 0 ? " \(count)" : ""
    }

    private func handleAuthRequest(_ pending: IPCServer.PendingAuthRequest) {
        let request = pending.request
        let caller = TrustPromptModel.sanitizedCaller(request.callerIdentity?.displayName ?? L("Unknown Caller"))
        registerAuthApproval(
            // Any local process can rename a credential without a prompt and put anything in its
            // session label: both go through the strong sanitiser here too. 【独立审计第二轮】
            title: L("\(caller) wants to use \(CallerStatedReason.printableLine(request.credentialLabel, limit: 80))"),
            detail: ([request.fieldNames.joined(separator: ", ")]
                     + [request.sessionLabel.map { CallerStatedReason.printableLine(AppL10n.text($0), limit: 80) }].compactMap { $0 })
                .joined(separator: " · "),
            deny: { [weak self] in
                self?.ipcServer.respond(to: pending, with: AuthResponse(granted: false, error: "User denied"))
            }
        )

        // Errors propagate to the window, which shows them and stays open so the
        // user can pick another option; the CLI keeps waiting on the same request.
        let authorize: (AuthorizationView.DurationChoice) throws -> Void = { [weak self] choice in
                guard let self else { return }
                guard self.ipcServer.isLive(pending) else { throw ApprovalIssuanceError.requestEnded }
                let resolved = try DurationResolution.issued(choice, sessionId: request.sessionId, identity: request.callerIdentity)
                // Scoped to the program that asked: every key of this credential, for that caller.
                let approval = Approval(
                    subject: ApprovalSubject(fingerprint: request.callerIdentity?.subject.fingerprint ?? "",
                                             displayName: request.callerIdentity?.displayName ?? L("Unknown Caller")),
                    target: .credential(id: request.credentialId, fields: nil),
                    duration: resolved,
                    onceFieldsRemaining: resolved == .once ? request.fieldNames : nil,
                    reason: request.statedReason?.text,
                    command: request.commandSummary
                )
                try ApprovalStore.shared.add(approval)
                self.ipcServer.respond(to: pending, with: AuthResponse(granted: true, grantId: approval.id))
        }
        let deny: () -> Void = { [weak self] in
            self?.ipcServer.respond(to: pending, with: AuthResponse(granted: false, error: "User denied"))
        }
        // An isolated e2e instance answers itself; the window never appears.
        if let auto = TestInstance.autoApprove {
            do { try authorize(auto.choice) } catch { deny() }
            clearAuthApproval()
            return
        }
        if ApprovalAlertPreferences.shouldPlaySound() { NSSound.beep() }
        authWindowController.show(
            request: request,
            waiting: ipcServer.waitingCount,
            review: requestReview(for: .strict(request)),
            onAuthorize: authorize,
            onDeny: deny
        )
    }

    private func handleServiceRequest(_ pending: IPCServer.PendingServiceRequest) {
        let caller = TrustPromptModel.sanitizedCaller(pending.callerIdentity.displayName)
        registerAuthApproval(
            title: L("\(caller) wants to use \(pending.credentialLabel)"),
            detail: pending.fieldNames.joined(separator: ", "),
            deny: { [weak self] in self?.ipcServer.denyServiceRequest(pending) }
        )

        let authorize: (AuthorizationView.DurationChoice) throws -> Void = { [weak self] choice in
                guard let self else { return }
                guard self.ipcServer.isLive(pending) else { throw ApprovalIssuanceError.requestEnded }
                let duration = try DurationResolution.issued(choice, sessionId: pending.request.sessionId, identity: pending.callerIdentity)
                let approval = Approval(
                    subject: ApprovalSubject(fingerprint: pending.callerIdentity.subjectFingerprint,
                                             displayName: pending.callerIdentity.displayName),
                    target: .credential(id: pending.credentialId, fields: pending.fieldNames),
                    duration: duration,
                    onceFieldsRemaining: duration == .once ? pending.fieldNames : nil,
                    reason: pending.request.statedReason?.text,
                    command: pending.request.commandSummary
                )
                // An unidentified caller gets this one answer and nothing remembered.
                do {
                    try ApprovalStore.shared.add(approval)
                    self.ipcServer.fulfillServiceRequest(pending, approval: approval)
                } catch ApprovalIssuanceError.unidentifiedCaller {
                    self.ipcServer.fulfillServiceRequest(pending, approval: nil)
                }
        }
        if let auto = TestInstance.autoApprove {
            do { try authorize(auto.choice) } catch { ipcServer.denyServiceRequest(pending) }
            clearAuthApproval()
            return
        }
        if ApprovalAlertPreferences.shouldPlaySound() { NSSound.beep() }
        authWindowController.show(
            serviceRequest: pending,
            waiting: ipcServer.waitingCount,
            review: requestReview(for: .service(pending)),
            onAuthorize: authorize,
            onDeny: { [weak self] in
                self?.ipcServer.denyServiceRequest(pending)
            }
        )
    }

    /// From the access log: a caller asked, nobody answered in time — approve it now so the next
    /// call goes through. Same window, same answers, no live request waiting behind it.
    private func handleStandingApproval(_ request: StandingApprovalRequest) {
        let authorize: (AuthorizationView.DurationChoice) throws -> Void = { choice in
            let duration = try DurationResolution.issued(choice, sessionId: nil, identity: request.callerIdentity)
            try ApprovalStore.shared.add(Approval(
                subject: ApprovalSubject(fingerprint: request.callerIdentity.subject.fingerprint,
                                         displayName: request.callerIdentity.displayName),
                target: .credential(id: request.credentialId, fields: nil),
                duration: duration,
                onceFieldsRemaining: duration == .once ? request.fieldNames : nil,
                reason: request.reason, command: request.command))
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        }
        authWindowController.show(standing: request, review: requestReview(for: .standing(request)), onAuthorize: authorize, onDeny: {})
    }

    /// The declared use and expiry come from meta.json; a missing or unreadable file just means
    /// the rules have less to go on.
    private func requestReview(for prompt: AuthorizationPrompt) -> RequestReview {
        let credential = (try? MetaStore.default.load())?.credentials[prompt.credentialId]
        return RequestReview.make(prompt: prompt, credential: credential, approvals: .shared)
    }

    static func shouldShowPopoverOnLaunch(setupComplete: Bool) -> Bool {
        !setupComplete
    }

    func showPopover() {
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
        showMainWindow()
    }

    @objc private func menuCheckForUpdates() {
        updateController.checkForUpdates()
    }

    @objc private func menuToggleLaunchAtLogin() {
        do {
            try LoginItemManager.setEnabled(!LoginItemManager.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Couldn't change Launch at Login")
            alert.informativeText = error.localizedDescription + L("\n\nYou can also add KeyKeeper under System Settings › General › Login Items.")
            alert.runModal()
        }
    }

    @objc private func menuSettings() {
        showMainWindow(section: .settings)
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
