import AppKit
import SwiftUI
import KeyKeeperCore

/// Everything a one-time confirmation needs to say, in the order people read it:
/// what is being asked, three facts, one reassurance, then the fine print folded away.
///
/// Before this, each confirmation was a hand-built AppKit stack of seven equally weighted
/// paragraphs with two blue buttons; the save panel, the website-session panel and the
/// authorization window each had different button rules. The moment a user decides to
/// trust an agent deserves the most care, so every save and website-session prompt now
/// shares this one model and view.
struct TrustPromptModel: Equatable {
    enum Tone: Equatable { case reassuring, caution, destructive }

    enum RowIcon: Equatable {
        case provider(String)
        case caller(String)
    }

    struct Row: Equatable {
        var label: String
        var value: String
        var monospaced = false
        /// A mark drawn before the value: the provider's brand mark, or the calling app's icon.
        var icon: RowIcon?
        /// Full text on hover when `value` is shortened (e.g. a file path).
        var help: String?
        /// One short line under the value, in the body font (never monospaced).
        var note: String?
    }

    var title: String
    var subtitle: String
    var rows: [Row]
    var assurance: String
    var tone: Tone = .reassuring
    var details: [String]
    var confirmTitle: String
    var expiresAt: Date?
    /// Ask how long, not just yes or no (opening a website login for an identified caller).
    var offersDurations = false
    /// Bumped by the presenter when the rows change under an open window (the clipboard moved):
    /// the confirm button goes back through its settle delay, so a click already on its way
    /// cannot land on content that was swapped in a moment ago.
    var settleToken = 0

    /// Caller names come from the requesting process; keep them to one printable line.
    ///
    /// 【独立审计 2026-09-13】this used to drop control characters only: private-use scalars were
    /// drawn as-is and a newline silently glued two lines into one name. The authorization window
    /// uses the strong sanitiser; the save prompts and the menu-bar list use it too now.
    static func sanitizedCaller(_ name: String) -> String {
        let line = CallerStatedReason.printableLine(name, limit: 80)
        return line.isEmpty ? L("Unknown Caller") : line
    }

    // MARK: Saves (clipboard, browser paste, service-account file, Python source)

    static func save(_ info: ClipboardSaveController.Presentation, now: Date = Date()) -> TrustPromptModel {
        let caller = sanitizedCaller(info.callerName)
        let request = info.request
        let target = "\(request.credentialId) · \(request.fieldName)"
        if request.isReplacement {
            var details = [L("Copy exactly once after this request, then confirm. Failed checks keep the old value. Existing permissions still apply to the replacement. This request expires in 90 seconds.")]
            if let expected = request.expectedEd25519PublicKey {
                details.append(L("Expected public key (caller supplied): \(expected)"))
            }
            return TrustPromptModel(
                title: L("Replace this saved value?"), subtitle: L("\(caller) wants to put it in KeyKeeper"),
                rows: [Row(label: L("Save as"), value: target, monospaced: true, note: L("Replace existing value")),
                       Row(label: L("Source"), value: L("Clipboard · copied after this request")),
                       Row(label: L("Requested by"), value: caller),
                       Row(label: L("Expected format"), value: request.expect ?? "", monospaced: true)],
                assurance: L("Only this field is replaced after validation. Permissions stay unchanged. The caller never sees the value."),
                tone: .caution, details: details, confirmTitle: L("Replace value"), expiresAt: info.expiresAt)
        }
        // A caller may suggest a looser level for a key meant for unattended use. The suggestion is
        // only ever applied by approving this prompt, so it has to be stated here, attributed.
        let proposed = request.security ?? .strict
        let saveAsNote = request.create
            ? (proposed == .strict ? L("New, Ask every time") : L("New, Background OK"))
            : request.addField ? L("Adds a new secret field") : L("Fills in the missing value")

        let title: String
        let source: Row
        let assurance: String
        var details: [String]
        if let path = info.filePath, let symbol = info.pythonSymbol {
            let name = (path as NSString).lastPathComponent
            title = L("Save a key found in source code?")
            source = Row(label: L("Source"), value: "\(name) · \(symbol)", monospaced: true, help: path)
            assurance = L("Only this variable's text is read; the code is never run. \(caller) never sees the value.")
            details = [L("Python source · up to 1 MiB. Only the selected string literal or environment default is extracted after approval. Source code is never executed. This is a candidate, not a verified runtime or provider credential. The original is retained; no value is shown.")]
        } else if let path = info.filePath {
            title = L("Save a service-account file?")
            source = Row(label: L("Source"), value: (path as NSString).lastPathComponent, monospaced: true, help: path)
            assurance = L("\(caller) never sees the file. The original stays where it is, and nothing is overwritten.")
            details = [L("Service-account JSON · up to 64 KiB. The App reads this file only after approval. The original file is NOT deleted. File contents are not shown here; provider access is not verified.")]
        } else if info.fromBrowser {
            title = L("Save the value pasted in your browser?")
            source = Row(label: L("Source"), value: L("Browser paste page on this Mac"))
            assurance = L("\(caller) never sees the value, and nothing is overwritten.")
            details = [L("Save the value just pasted into the local browser receiver. No value is shown to the caller. Nothing is overwritten and no read permission is granted. Website identity is not verified. After paste, KeyKeeper holds this proposal locally for 10 minutes even if the page or CLI closes.")]
        } else {
            // yyt 2026-09-14: whatever is on the clipboard now, shown so the person can tell.
            title = L("Save what is on the clipboard?")
            let copied = info.preview.map { $0.copiedAt.map { L("copied \(copiedAgo($0, now: now))") } ?? L("copied before KeyKeeper started") }
            source = Row(label: L("Source"), value: copied.map { L("Clipboard") + " · " + $0 } ?? L("Clipboard"))
            assurance = L("\(caller) never sees the value. Nothing is overwritten, and the clipboard is cleared after saving.")
            details = [L("The line above shows the first and last characters and the length, so you can tell it is the right thing without the value being displayed. Copy again if it is not — this window follows the clipboard. The clipboard is cleared after saving. This request expires in 90 seconds.")]
        }
        if info.filePath != nil {
            details.append(L("Nothing is overwritten and no read permission is granted. If the file changes, this save is refused. This request expires in 90 seconds."))
        }
        details.append(request.create
            ? (proposed == .strict
                ? L("Create a new credential with Ask every time protection.")
                : L("Create a new credential that background callers can use after you approve each one once, as \(caller) suggested."))
            : request.addField
                ? L("Add a new secret field. Existing read permissions stay limited to the old fields.")
                : L("Restore this missing field. Keep its existing settings and permissions."))

        var rows = [
            Row(label: L("Save as"), value: target, monospaced: true, note: saveAsNote),
            source,
            Row(label: L("Requested by"), value: caller, icon: .caller(info.callerName)),
        ]
        var looksLikeProse = false
        if let preview = info.preview {
            var parts = [preview.masked, L("\(preview.shape.characters) characters")]
            if preview.shape.lines > 1 { parts.append(L("\(preview.shape.lines) lines")) }
            else if preview.shape.hasWhitespace { parts.append(L("has spaces")) }
            looksLikeProse = preview.shape.lines > 1 || preview.shape.hasWhitespace
            rows.append(Row(label: L("Looks like"), value: parts.joined(separator: " · "), monospaced: true,
                            note: looksLikeProse ? L("Keys rarely have spaces or several lines. Check what you copied.") : nil))
        }
        // The three facts stay first and in place; a suggestion adds a line after them.
        if request.create, request.security != nil {
            rows.append(Row(label: L("Protection"), value: SecurityLevelPresentation.badge(proposed),
                            note: L("Suggested by \(caller)")))
        }
        if request.create, let expires = request.expires {
            rows.append(Row(label: L("Expires"), value: expires, monospaced: true, note: L("Suggested by \(caller)")))
        }
        if let template = request.provider.flatMap(ProviderCatalog.find) {
            var providerNotes: [String] = []
            if let validation = template.validation {
                providerNotes.append(L("Checked after saving with a read-only request to \(validation.host)."))
            }
            if let expiry = template.expiryNote {
                providerNotes.append(L("Expires") + ": " + expiry)
            }
            rows.append(Row(label: L("Provider"), value: template.name, icon: .provider(template.id),
                            note: providerNotes.isEmpty ? nil : providerNotes.joined(separator: " ")))
        }
        // The caller's declaration, and what the rules make of the protection it suggested.
        var inflated = false
        if request.create, let intent = request.intent?.sanitized() {
            var tail = [RequestReview.frequencyName(intent.frequency)]
            if intent.background { tail.append(L("unattended")) }
            if let expected = intent.expectedCaller { tail.append(expected) }
            rows.append(Row(label: L("Declared use"), value: intent.purpose, note: tail.joined(separator: " · ") + " · " + L("Declared by \(caller)")))
        }
        if request.create, request.security != nil || request.intent != nil {
            let review = IntentRules.review(IntentReviewInput(
                credentialId: request.credentialId, credentialLabel: request.credentialId, fieldNames: [request.fieldName],
                callerName: caller, intent: request.intent?.sanitized(), expires: request.expires, requestedSecurity: proposed))
            if let finding = review.findings.first {
                inflated = review.verdict == .inflated
                let suggestion = review.suggestedSecurity.map { SecurityLevelPresentation.badge($0) + " — " } ?? ""
                rows.append(Row(label: L("KeyKeeper suggests"), value: suggestion + RequestReview.findingText(finding),
                                note: inflated ? L("Saving keeps the caller's suggestion; change the protection afterwards in the app.") : nil))
            }
        }

        return TrustPromptModel(
            title: title,
            subtitle: L("\(caller) wants to put it in KeyKeeper"),
            rows: rows,
            assurance: assurance,
            tone: proposed == .standard || inflated || looksLikeProse ? .caution : .reassuring,
            details: details,
            confirmTitle: L("Save"),
            expiresAt: info.expiresAt
        )
    }

    /// "just now", "10 s ago", "3 min ago", "2 h ago".
    static func copiedAgo(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded(.down))
        if seconds < 5 { return L("just now") }
        if seconds < 60 { return L("\(seconds) s ago") }
        if seconds < 3600 { return L("\(seconds / 60) min ago") }
        return L("\(seconds / 3600) h ago")
    }

    // MARK: Website sessions

    static func browserSession(_ info: BrowserSessionPresentation, expiresAt: Date?) -> TrustPromptModel {
        let caller = sanitizedCaller(info.caller)
        let isDelete = info.action == .delete
        let details = [
            isDelete
                ? L("This stops the managed window and deletes only this saved snapshot. Chrome and the website account remain unchanged.")
                : L("This can grant account actions, not just reading. Only this site opens in a temporary window; cross-site navigation and file uploads are blocked. Closing it does not revoke the website session."),
            info.offersDurations
                ? L("Cookie values are never returned to the caller. Choosing longer than once lets this caller open this login again without asking, until the time is up or you revoke it on the Website sessions page.")
                : L("One request only · expires in 90 seconds · Cookie values are never returned to the caller."),
        ]
        let confirm: String
        switch info.action {
        case .open: confirm = L("Open")
        case .delete: confirm = L("Delete")
        default: confirm = L("Save")
        }
        return TrustPromptModel(
            title: BrowserSessionCopy.action(info.action),
            subtitle: L("Requested by: \(caller)"),
            rows: [
                Row(label: L("Website"), value: info.session.origin, monospaced: true),
                Row(label: L("Snapshot"), value: L("\(CallerStatedReason.printableLine(info.session.label, limit: 80)) · \(info.session.cookieCount) Cookies")),
                Row(label: L("Requested by"), value: caller),
            ],
            assurance: isDelete
                ? L("Only this snapshot is deleted. Chrome and the website account are unchanged.")
                : L("This window can act on the account, not just view it."),
            tone: isDelete ? .destructive : .caution,
            details: details,
            confirmTitle: confirm,
            expiresAt: expiresAt,
            offersDurations: info.offersDurations
        )
    }
}

// MARK: - View

struct TrustPromptView: View {
    let model: TrustPromptModel
    let onCancel: () -> Void
    let onConfirm: () -> Void
    /// Set when the prompt asks how long; the confirm button then answers with the chosen duration.
    var onConfirmDuration: ((ApprovalDuration) -> Void)? = nil
    @State private var showDetails = false
    @State private var duration: SessionDurationOption = .once
    /// 【独立审计 2026-09-13】saves and website sessions had no settle delay: a click already on its
    /// way could land on a prompt that had only just appeared. Same rule as the authorization window.
    @State private var canConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title)
                        .font(.system(size: 17, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.subtitle)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.label)
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                switch row.icon {
                                case .provider(let id): ProviderMark(providerId: id, size: 18, colored: true)
                                case .caller(let id): CallerMark(callerId: id, size: 18)
                                case nil: EmptyView()
                                }
                                Text(row.value)
                                    .font(row.monospaced ? .callout.monospaced() : .callout)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .help(row.help ?? row.value)
                            }
                            if let note = row.note {
                                Text(note).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.vertical, 9)
                    if index < model.rows.count - 1 {
                        GlassSeparator()
                    }
                }
            }
            .padding(.horizontal, 14)
            .glassCard()

            Label {
                Text(model.assurance)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: model.tone == .reassuring ? "lock.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(model.tone == .reassuring ? .secondary : .orange)
            }
            .font(.callout)

            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.details, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(L("Details")).font(.caption).foregroundColor(.accentColor)
            }

            if model.offersDurations {
                Picker(L("Allow for"), selection: $duration) {
                    ForEach(SessionDurationOption.allCases, id: \.self) { option in
                        Text(AppL10n.text(option.rawValue)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 10) {
                if let expiresAt = model.expiresAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded(.up)))
                        Text(L("Cancels in \(seconds) s"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Button(L("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                // No keyboard shortcut at all, like the authorization window. ⌘↩ is "send" in chat
                // and comment boxes, and this prompt takes focus: a keystroke meant for them must
                // never approve it. 【独立审计第二轮】
                Button(action: {
                    if let onConfirmDuration { onConfirmDuration(duration.grantDuration) } else { onConfirm() }
                }) {
                    Text(model.confirmTitle).frame(minWidth: 52)
                }
                .disabled(!canConfirm)
                .buttonStyle(.borderedProminent)
                .tint(model.tone == .destructive ? .red : .accentColor)
                .controlSize(.large)
            }
        }
        .padding(24)
        .glassPanel(width: 440, intensity: 0.8)
        .onAppear { settle() }
        .onChange(of: model.settleToken) { _, _ in settle() }
    }

    private func settle() {
        canConfirm = false
        let token = model.settleToken
        DispatchQueue.main.asyncAfter(deadline: .now() + ApprovalReadiness.settleDelay) {
            if token == model.settleToken { canConfirm = true }
        }
    }
}

// MARK: - Presenter

/// Shows a `TrustPromptModel` in a floating panel and mirrors it into the menu bar's
/// "Waiting for you" list, so the request can be answered from either place.
@MainActor final class TrustPromptPresenter: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var decide: ((Bool) -> Void)?
    private var decideDuration: ((ApprovalDuration?) -> Void)?
    private var approvalID: UUID?
    private let center: ApprovalCenter
    /// What the open panel currently shows (tests read it; the panel is the source of truth).
    private(set) var installedModel: TrustPromptModel?

    init(center: ApprovalCenter = .shared) {
        self.center = center
    }

    func show(_ model: TrustPromptModel, symbol: String, decide: @escaping (Bool) -> Void) {
        present(model, symbol: symbol, decide: decide, decideDuration: nil)
    }

    /// A prompt that also asks how long. Its entry in the menu-bar list can only bring the window
    /// forward: approving from the list would mean picking a duration on the person's behalf.
    func show(_ model: TrustPromptModel, symbol: String, decideDuration: @escaping (ApprovalDuration?) -> Void) {
        present(model, symbol: symbol, decide: nil, decideDuration: decideDuration)
    }

    private func present(_ model: TrustPromptModel, symbol: String,
                         decide: ((Bool) -> Void)?, decideDuration: ((ApprovalDuration?) -> Void)?) {
        dismiss()
        self.decide = decide
        self.decideDuration = decideDuration
        let asksDuration = decideDuration != nil

        let id = UUID()
        approvalID = id
        center.add(.init(
            id: id,
            symbol: symbol,
            title: model.title,
            detail: model.rows.first.map { "\($0.label) \($0.value)" } ?? model.subtitle,
            expiresAt: model.expiresAt,
            confirmTitle: model.confirmTitle,
            destructive: model.tone == .destructive,
            opensWindow: asksDuration,
            confirm: { [weak self] in
                if asksDuration { NSApp.activate(ignoringOtherApps: true); self?.panel?.makeKeyAndOrderFront(nil) }
                else { self?.resolve(true) }
            },
            deny: { [weak self] in self?.resolve(false) }
        ))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = "KeyKeeper"
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        installedModel = model
        let hosting = NSHostingView(rootView: TrustPromptView(
            model: model,
            onCancel: { [weak self] in self?.resolve(false) },
            onConfirm: { [weak self] in self?.resolve(true) },
            onConfirmDuration: asksDuration ? { [weak self] in self?.resolveDuration($0) } : nil
        ))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        self.panel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Same panel, new rows — the clipboard moved while a save prompt was up.
    func update(_ model: TrustPromptModel) {
        guard let hosting = panel?.contentView as? NSHostingView<TrustPromptView> else { return }
        var model = model
        model.settleToken = (installedModel?.settleToken ?? 0) + 1
        installedModel = model
        hosting.rootView = TrustPromptView(model: model, onCancel: hosting.rootView.onCancel,
                                           onConfirm: hosting.rootView.onConfirm,
                                           onConfirmDuration: hosting.rootView.onConfirmDuration)
        panel?.setContentSize(hosting.fittingSize)
    }

    func bringToFront() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        if let approvalID { center.remove(id: approvalID) }
        approvalID = nil
        decide = nil
        decideDuration = nil
        panel?.orderOut(nil)
        panel = nil
        installedModel = nil
    }

    private func resolve(_ approved: Bool) {
        let reply = decide, durationReply = decideDuration
        decide = nil
        decideDuration = nil
        if let durationReply { durationReply(approved ? .once : nil) } else { reply?(approved) }
    }

    private func resolveDuration(_ duration: ApprovalDuration) {
        let durationReply = decideDuration
        decide = nil
        decideDuration = nil
        durationReply?(duration)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        resolve(false)
        return false
    }
}

/// How long one caller may open one website login without asking again.
enum SessionDurationOption: String, CaseIterable {
    case once = "Just this once"
    case oneHour = "1 hour"
    case always = "Always"

    var grantDuration: ApprovalDuration {
        switch self {
        case .once: return .once
        case .oneHour: return .timed(Date().addingTimeInterval(3600))
        case .always: return .always
        }
    }
}
