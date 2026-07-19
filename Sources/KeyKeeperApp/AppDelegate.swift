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
            button.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "KeyKeeper")
            button.action = #selector(togglePopover)
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 480)
        popover.behavior = .semitransient
        popover.contentViewController = NSHostingController(rootView: MainView())

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

        // Auto-show popover on launch so user knows the app is running
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showPopover()
        }
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
            onAuthorize: { [weak self] duration in
                guard let self else { return }

                do {
                    // Resolve actual duration (fill in session ID for .session).
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

    private func handleServiceRequest(_ pending: IPCServer.PendingServiceRequest) {
        let serviceGrantStore = ServiceGrantStore.default

        authWindowController.show(
            serviceRequest: pending,
            onAuthorize: { [weak self] duration in
                guard let self else { return }

                do {
                    let grant = ServiceGrant(
                        credentialId: pending.credentialId,
                        subjectFingerprint: pending.callerIdentity.subjectFingerprint,
                        subjectDisplayName: pending.callerIdentity.displayName,
                        fields: pending.fieldNames,
                        duration: duration
                    )
                    try serviceGrantStore.addGrant(grant)
                    self.ipcServer.fulfillServiceRequest(pending, serviceGrant: grant)
                } catch {
                    self.ipcServer.denyServiceRequest(pending, message: error.localizedDescription)
                }
            },
            onDeny: { [weak self] in
                self?.ipcServer.denyServiceRequest(pending)
            }
        )
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        activatePopover()
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            activatePopover()
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
