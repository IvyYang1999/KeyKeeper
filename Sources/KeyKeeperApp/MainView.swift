import SwiftUI
import KeyKeeperCore

struct MainView: View {
    @StateObject private var viewModel: CredentialListViewModel
    @StateObject private var addVM: AddCredentialViewModel
    @State private var setupComplete = UserDefaults.standard.bool(forKey: "setupComplete")
    @State private var selectedCredentialId: String?
    @State private var showingAdd = false
    @State private var showSettings = false
    @State private var showServiceGrants = false
    @State private var serviceGrants: [ServiceGrant] = []

    @ObservedObject private var updateController: UpdateController

    @State private var pendingDeleteId: String?

    @ObservedObject private var inbox = UICommandInbox.shared

    private let serviceGrantStore = ServiceGrantStore.default
    private let session: any CredentialSessionManaging

    init(session: any CredentialSessionManaging, updateController: UpdateController) {
        self.session = session
        self.updateController = updateController
        _viewModel = StateObject(wrappedValue: CredentialListViewModel(session: session))
        _addVM = StateObject(wrappedValue: AddCredentialViewModel(session: session))
    }

    enum Page { case list, add, detail(String), serviceGrants, settings }

    private var currentPage: Page {
        if showServiceGrants { return .serviceGrants }
        if showSettings { return .settings }
        if showingAdd { return .add }
        if let id = selectedCredentialId { return .detail(id) }
        return .list
    }

    var body: some View {
        Group {
        if !setupComplete {
            SetupView(setupComplete: $setupComplete)
        } else {
            switch currentPage {
            case .list:
                credentialListContent
            case .add:
                AddCredentialView(
                    vm: addVM,
                    onSave: {
                        viewModel.load()
                        addVM.reset()
                        showingAdd = false
                    },
                    onCancel: {
                        // Keep draft — just go back to list
                        showingAdd = false
                    },
                    onOpenExisting: { id in
                        addVM.reset()
                        showingAdd = false
                        selectedCredentialId = id
                    }
                )
            case .detail(let id):
                if let item = viewModel.credentials.first(where: { $0.id == id }) {
                    CredentialDetailView(
                        credentialId: item.id,
                        credential: item.credential,
                        session: session,
                        onBack: { selectedCredentialId = nil },
                        onUpdate: { viewModel.load() },
                        onDelete: {
                            guard viewModel.delete(id: item.id) else {
                                return viewModel.errorMessage ?? "Delete failed"
                            }
                            selectedCredentialId = nil
                            return nil
                        }
                    )
                } else {
                    credentialListContent
                }
            case .serviceGrants:
                serviceGrantsView
            case .settings:
                SettingsView(
                    updateController: updateController,
                    onBack: { showSettings = false },
                    onShowServiceGrants: { showServiceGrants = true },
                    onShowSetup: {
                        showSettings = false
                        UserDefaults.standard.set(false, forKey: "setupComplete")
                        setupComplete = false
                    }
                )
            }
        }
        }
        // Handled on the outer body so every page responds, and so a request that arrived
        // before the popover was ever rendered is still picked up on first render.
        .onReceive(inbox.$pendingAddCredential.compactMap { $0 }) { link in
            guard case .addCredential(let label, let fields, let notes) = link else { return }
            addVM.prefill(label: label, fields: fields, notes: notes)
            showServiceGrants = false
            showSettings = false
            selectedCredentialId = nil
            showingAdd = true
            DispatchQueue.main.async { inbox.clearAddCredential() }
        }
        .onReceive(inbox.$pendingSettings.filter { $0 }) { _ in
            showServiceGrants = false
            showingAdd = false
            selectedCredentialId = nil
            showSettings = true
            DispatchQueue.main.async { inbox.clearSettings() }
        }
    }

    @ViewBuilder
    private var credentialListContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("KeyKeeper")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button(action: { showingAdd = true }) {
                    Image(systemName: "plus")
                }
                .help("New key group")
            }
            .padding()

            TextField("Search...", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if let failure = viewModel.loadFailure {
                Spacer()
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Label("Couldn't read your credential list", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.red)
                    Text("Your key values are safe in the macOS Keychain; only the list file failed to load. Nothing has been deleted.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(failure.reason)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(failure.fileURL.path)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([failure.fileURL])
                        }
                        .font(.caption)
                        Button("Try again") { viewModel.load() }
                            .font(.caption)
                    }
                }
                .dsCard(padding: DS.Spacing.md, fill: Color.red.opacity(0.08))
                .padding(.horizontal)
                Spacer()
            } else if viewModel.filtered.isEmpty {
                Spacer()
                if addVM.hasDraft {
                    VStack(spacing: 8) {
                        Text("No credentials stored")
                            .foregroundColor(.secondary)
                        Button("Continue editing draft") {
                            showingAdd = true
                        }
                        .font(.caption)
                    }
                } else {
                    VStack(spacing: DS.Spacing.sm) {
                        Text("No keys yet")
                            .foregroundColor(.secondary)
                        Text("Values are encrypted by the macOS Keychain. AI tools see only the names.")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, DS.Spacing.xl)
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        // Draft hint
                        if addVM.hasDraft {
                            Button(action: { showingAdd = true }) {
                                HStack {
                                    Image(systemName: "doc.badge.ellipsis")
                                    Text("Draft: \(addVM.draftTitle)")
                                        .lineLimit(1)
                                    Spacer()
                                    Text("Continue")
                                        .foregroundColor(.accentColor)
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .dsCard(padding: DS.Spacing.sm, fill: DS.Fill.cardSecondary)
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(viewModel.filtered, id: \.id) { item in
                            CredentialRow(id: item.id, credential: item.credential)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedCredentialId = item.id
                                }
                                .contextMenu {
                                    Button("Delete\u{2026}", role: .destructive) {
                                        pendingDeleteId = item.id
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, DS.Spacing.md)
                }
                .confirmationDialog(
                    "Delete \"\(credentialLabel(for: pendingDeleteId ?? ""))\"?",
                    isPresented: Binding(
                        get: { pendingDeleteId != nil },
                        set: { if !$0 { pendingDeleteId = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        if let id = pendingDeleteId {
                            viewModel.delete(id: id)
                        }
                        pendingDeleteId = nil
                    }
                    Button("Cancel", role: .cancel) { pendingDeleteId = nil }
                } message: {
                    Text(CredentialDeletionCopy.message(credentialId: pendingDeleteId ?? ""))
                }
            }
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        .onAppear { viewModel.load() }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: DS.Spacing.sm) {
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }

                HStack {
                    Button(action: { NSApplication.shared.terminate(nil) }) {
                        Label("Quit KeyKeeper", systemImage: "power")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("KeyKeeper starts again automatically the next time a key is requested.")
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, DS.Spacing.sm)
            .background(.regularMaterial)
        }
        .onAppear {
            loadServiceGrants()
        }
    }

    private func loadServiceGrants() {
        serviceGrants = (try? serviceGrantStore.grants()) ?? []
    }

    private func revokeServiceGrant(_ grantId: String) {
        try? serviceGrantStore.revokeGrant(id: grantId)
        loadServiceGrants()
    }

    private func credentialLabel(for id: String) -> String {
        viewModel.credentials.first(where: { $0.id == id })?.credential.label ?? id
    }

    // MARK: - Service Grants View

    @ViewBuilder
    private var serviceGrantsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    showServiceGrants = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Spacer()
            }
            .padding()

            Text("Approved background callers")
                .font(.title3.weight(.semibold))
                .padding(.horizontal)
                .padding(.bottom, DS.Spacing.sm)

            if serviceGrants.isEmpty {
                Spacer()
                VStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("No background callers approved yet")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.md) {
                        ForEach(groupedServiceGrants) { group in
                            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                                Text(credentialLabel(for: group.credentialId))
                                    .font(.callout.bold())

                                ForEach(group.grants) { grant in
                                    serviceGrantRow(grant)
                                    if grant.id != group.grants.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .dsCard()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, DS.Spacing.sm)
                }
            }
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        .onAppear { loadServiceGrants() }
    }

    private func serviceGrantRow(_ grant: ServiceGrant) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(grant.subjectDisplayName)
                    .font(.callout)

                HStack(spacing: 4) {
                    Text(grant.fields.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    Text("\u{00B7}")
                        .foregroundColor(.secondary)
                    Text(serviceDurationLabel(grant.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(serviceGrantTimeLabel(grant))
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
            }

            Spacer()

            Button("Revoke") {
                revokeServiceGrant(grant.id)
            }
            .font(.caption)
            .foregroundColor(.red)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var groupedServiceGrants: [ServiceGrantGroup] {
        Dictionary(grouping: serviceGrants, by: \.credentialId)
            .map { ServiceGrantGroup(credentialId: $0.key, grants: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { credentialLabel(for: $0.credentialId) < credentialLabel(for: $1.credentialId) }
    }

    private func serviceDurationLabel(_ duration: ServiceGrantDuration) -> String {
        switch duration {
        case .once:
            return "Once"
        case .timed(let date):
            if date > Date() {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                return "Expires \(formatter.localizedString(for: date, relativeTo: Date()))"
            } else {
                return "Expired"
            }
        case .always:
            return "Always"
        }
    }

    private func serviceGrantTimeLabel(_ grant: ServiceGrant) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        if let lastUsed = grant.lastUsedAt {
            return "Used \(formatter.localizedString(for: lastUsed, relativeTo: Date()))"
        }
        return "Created \(formatter.localizedString(for: grant.createdAt, relativeTo: Date()))"
    }
}

private struct ServiceGrantGroup: Identifiable {
    let credentialId: String
    let grants: [ServiceGrant]
    var id: String { credentialId }
}

enum CredentialDeletionCopy {
    static func message(credentialId: String) -> String {
        "Its key values are erased from the vault. This can't be undone, and anything running `keykeeper run -c \(credentialId)` will stop working."
    }
}
