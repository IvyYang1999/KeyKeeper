import SwiftUI
import KeyKeeperCore

struct MainView: View {
    @StateObject private var viewModel = CredentialListViewModel()
    @StateObject private var addVM = AddCredentialViewModel()
    @State private var setupComplete = UserDefaults.standard.bool(forKey: "setupComplete")
    @State private var selectedCredentialId: String?
    @State private var showingAdd = false

    enum Page { case list, add, detail(String) }

    private var currentPage: Page {
        if showingAdd { return .add }
        if let id = selectedCredentialId { return .detail(id) }
        return .list
    }

    var body: some View {
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
                    }
                )
            case .detail(let id):
                if let item = viewModel.credentials.first(where: { $0.id == id }) {
                    CredentialDetailView(
                        credentialId: item.id,
                        credential: item.credential,
                        onBack: { selectedCredentialId = nil },
                        onUpdate: { viewModel.load() }
                    )
                } else {
                    credentialListContent
                }
            }
        }
    }

    @ViewBuilder
    private var credentialListContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("KeyKeeper")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: { showingAdd = true }) {
                    Image(systemName: "plus")
                }
            }
            .padding()

            TextField("Search...", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if viewModel.filtered.isEmpty {
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
                    Text("No credentials stored")
                        .foregroundColor(.secondary)
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
                                    Text("Draft: \(addVM.label)")
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
                                    Button("Delete", role: .destructive) {
                                        viewModel.delete(id: item.id)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, DS.Spacing.md)
                }
            }
        }
        .frame(width: 360, height: 480)
        .onAppear { viewModel.load() }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Label("Quit KeyKeeper", systemImage: "power")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }
}
