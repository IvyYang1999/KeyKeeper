import SwiftUI
import KeyKeeperCore

struct MainView: View {
    @StateObject private var viewModel = CredentialListViewModel()
    @State private var showingAdd = false
    @State private var setupComplete = UserDefaults.standard.bool(forKey: "setupComplete")
    @State private var selectedCredentialId: String?

    var body: some View {
        if setupComplete {
            if let selectedId = selectedCredentialId,
               let item = viewModel.credentials.first(where: { $0.id == selectedId }) {
                CredentialDetailView(
                    credentialId: item.id,
                    credential: item.credential,
                    onBack: { selectedCredentialId = nil },
                    onUpdate: { viewModel.load() }
                )
            } else {
                credentialListContent
            }
        } else {
            SetupView(setupComplete: $setupComplete)
        }
    }

    @ViewBuilder
    private var credentialListContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("KeyKeeper")
                    .font(.headline)
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
                Text("No credentials stored")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
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
                    .padding(.top, 8)
                }
            }
        }
        .frame(width: 360, height: 480)
        .onAppear { viewModel.load() }
        .sheet(isPresented: $showingAdd) {
            AddCredentialView(onSave: { viewModel.load() })
        }
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
            .padding(.bottom, 8)
        }
    }
}
