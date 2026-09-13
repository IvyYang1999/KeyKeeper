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

    struct Row: Equatable {
        var label: String
        var value: String
        var monospaced = false
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

    /// Caller names come from the requesting process; keep them to one printable line.
    static func sanitizedCaller(_ name: String) -> String {
        let printable = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = String(printable.prefix(80)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? L("Unknown Caller") : trimmed
    }

    // MARK: Saves (clipboard, browser paste, service-account file, Python source)

    static func save(_ info: ClipboardSaveController.Presentation) -> TrustPromptModel {
        let caller = sanitizedCaller(info.callerName)
        let request = info.request
        let target = "\(request.credentialId) · \(request.fieldName)"
        let saveAsNote = request.create ? L("New, Ask every time") : L("Fills in the missing value")

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
            details = [L("Save the value just pasted into the local browser receiver. No value is shown to the caller. Nothing is overwritten and no read permission is granted. Website identity is not verified. This request expires in 90 seconds.")]
        } else {
            title = L("Save what you just copied?")
            source = Row(label: L("Source"), value: L("Clipboard"))
            assurance = L("\(caller) never sees the value. Nothing is overwritten, and the clipboard is cleared after saving.")
            details = [L("The App will read your current clipboard. No value is shown to the caller. Nothing is overwritten and no read permission is granted. The clipboard is cleared after saving. This request expires in 90 seconds.")]
        }
        if info.filePath != nil {
            details.append(L("Nothing is overwritten and no read permission is granted. If the file changes, this save is refused. This request expires in 90 seconds."))
        }
        details.append(request.create
            ? L("Create a new credential with Ask every time protection.")
            : L("Restore this missing field. Keep its existing settings and permissions."))

        return TrustPromptModel(
            title: title,
            subtitle: L("\(caller) wants to put it in KeyKeeper"),
            rows: [
                Row(label: L("Save as"), value: target, monospaced: true, note: saveAsNote),
                source,
                Row(label: L("Requested by"), value: caller),
            ],
            assurance: assurance,
            details: details,
            confirmTitle: L("Save"),
            expiresAt: info.expiresAt
        )
    }

    // MARK: Website sessions

    static func browserSession(_ info: BrowserSessionPresentation, expiresAt: Date?) -> TrustPromptModel {
        let caller = sanitizedCaller(info.caller)
        let isDelete = info.action == .delete
        let details = [
            isDelete
                ? L("This stops the managed window and deletes only this saved snapshot. Chrome and the website account remain unchanged.")
                : L("This can grant account actions, not just reading. Only this site opens in a temporary window; cross-site navigation and file uploads are blocked. Closing it does not revoke the website session."),
            L("One request only · expires in 90 seconds · Cookie values are never returned to the caller."),
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
                Row(label: L("Snapshot"), value: L("\(info.session.label) · \(info.session.cookieCount) Cookies")),
                Row(label: L("Requested by"), value: caller),
            ],
            assurance: isDelete
                ? L("Only this snapshot is deleted. Chrome and the website account are unchanged.")
                : L("This window can act on the account, not just view it."),
            tone: isDelete ? .destructive : .caution,
            details: details,
            confirmTitle: confirm,
            expiresAt: expiresAt
        )
    }
}

// MARK: - View

struct TrustPromptView: View {
    let model: TrustPromptModel
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var showDetails = false

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
                            Text(row.value)
                                .font(row.monospaced ? .callout.monospaced() : .callout)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(row.help ?? row.value)
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
                // ⌘↩ confirms. Plain Return deliberately does nothing, so a keystroke meant
                // for the terminal can never approve a request that just stole focus.
                Button(action: onConfirm) {
                    Text(model.confirmTitle).frame(minWidth: 52)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(model.tone == .destructive ? .red : .accentColor)
                .controlSize(.large)
                .help("⌘↩")
            }
        }
        .padding(24)
        .glassPanel(width: 440, intensity: 0.8)
    }
}

// MARK: - Presenter

/// Shows a `TrustPromptModel` in a floating panel and mirrors it into the menu bar's
/// "Waiting for you" list, so the request can be answered from either place.
@MainActor final class TrustPromptPresenter: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var decide: ((Bool) -> Void)?
    private var approvalID: UUID?
    private let center: ApprovalCenter

    init(center: ApprovalCenter = .shared) {
        self.center = center
    }

    func show(_ model: TrustPromptModel, symbol: String, decide: @escaping (Bool) -> Void) {
        dismiss()
        self.decide = decide

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
            opensWindow: false,
            confirm: { [weak self] in self?.resolve(true) },
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
        let hosting = NSHostingView(rootView: TrustPromptView(
            model: model,
            onCancel: { [weak self] in self?.resolve(false) },
            onConfirm: { [weak self] in self?.resolve(true) }
        ))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        self.panel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        if let approvalID { center.remove(id: approvalID) }
        approvalID = nil
        decide = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func resolve(_ approved: Bool) {
        let reply = decide
        decide = nil
        reply?(approved)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        resolve(false)
        return false
    }
}
