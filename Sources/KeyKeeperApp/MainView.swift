import SwiftUI

struct MainView: View {
    @StateObject private var viewModel = CredentialListViewModel()
    @State private var showingAdd = false
    @State private var setupComplete = UserDefaults.standard.bool(forKey: "setupComplete")

    var body: some View {
        if setupComplete {
            credentialListContent
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
                List {
                    ForEach(viewModel.filtered, id: \.id) { item in
                        CredentialRow(id: item.id, credential: item.credential)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    viewModel.delete(id: item.id)
                                }
                            }
                    }
                }
                .listStyle(.plain)
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
