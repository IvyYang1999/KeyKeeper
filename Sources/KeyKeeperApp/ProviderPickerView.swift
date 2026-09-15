import SwiftUI
import KeyKeeperCore

/// Keeps all browsing state inside the popover: opening, searching and cancelling never write.
struct ProviderPickerButton: View {
    @Binding var selection: String
    @State private var isPresented = false

    private var provider: ProviderTemplate? { ProviderCatalog.find(selection) }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 6) {
                if let provider {
                    ProviderMark(providerId: provider.id, size: 18, colored: true)
                }
                Text(provider?.name ?? (selection.isEmpty ? L("Choose provider") : selection))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Choose provider"))
        .accessibilityValue(provider?.name ?? selection)
        .accessibilityIdentifier("provider-picker")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ProviderPickerView(selectedID: selection) { id in
                // An old alias resolved for display must not migrate on an unchanged selection.
                if id != selection { selection = id }
                isPresented = false
            }
        }
    }
}

struct ProviderPickerView: View {
    let selectedID: String
    let onSelect: (String) -> Void
    @State private var query = ""
    @State private var category: ProviderCategory?
    @State private var highlightedID: String?
    @Environment(\.dismiss) private var dismiss

    private var results: [ProviderTemplate] { ProviderBrowser.results(query: query, category: category) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Choose provider")).font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(L("Close provider picker"))
            }
            ProviderSearchField(text: $query, onMove: { delta in
                highlightedID = ProviderBrowser.movedHighlight(highlightedID, by: delta, in: results)
            }, onSubmit: { selectHighlighted() }, onCancel: { dismiss() })
                .frame(height: 30)
            HStack {
                Picker(L("All categories"), selection: $category) {
                    Text(L("All categories")).tag(nil as ProviderCategory?)
                    ForEach(ProviderCategory.allCases) { category in
                        Text(category.title).tag(Optional(category))
                    }
                }
                .labelsHidden().frame(maxWidth: 205)
                .accessibilityIdentifier("provider-category")
                Spacer()
                Text(L("\(results.count) providers")).font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if results.isEmpty {
                            VStack(spacing: 8) {
                                Text(L("No matching providers")).font(.headline)
                                Text(L("Try another name or category.")).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 44)
                            .accessibilityIdentifier("provider-empty")
                        }
                        ForEach(results) { provider in
                            ProviderPickerRow(provider: provider,
                                selected: provider.id == selectedID,
                                highlighted: provider.id == highlightedID) { onSelect(provider.id) }
                                .id(provider.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: highlightedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(L("Choose the matching region and plan."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("No provider")) { onSelect("") }
                    .font(.caption).buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 430, height: 500)
        .onAppear {
            highlightedID = results.contains(where: { $0.id == selectedID }) ? selectedID : results.first?.id
        }
        .onChange(of: query) { _, _ in highlightedID = results.first?.id }
        .onChange(of: category) { _, _ in highlightedID = results.first?.id }
        .onExitCommand { dismiss() }
    }

    private func selectHighlighted() {
        if let id = highlightedID, results.contains(where: { $0.id == id }) { onSelect(id) }
    }
}

private struct ProviderPickerRow: View {
    let provider: ProviderTemplate
    let selected: Bool
    let highlighted: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProviderMark(providerId: provider.id, size: 25, colored: true)
                    .frame(width: 30, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.system(size: 13, weight: .medium))
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(provider.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Image(systemName: "checkmark").font(.caption.weight(.semibold))
                    .opacity(selected ? 1 : 0).accessibilityHidden(true)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background((hovered || highlighted) ? Glass.fill(.raised, scheme) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityLabel(provider.name + ", " + provider.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("provider-option-" + provider.id)
    }
}

struct ProviderManagementLink: View {
    let providerID: String?
    var body: some View {
        if let url = ProviderBrowser.managementURL(for: providerID) {
            Link(destination: url) {
                HStack(spacing: 5) {
                    Text(L("Open dashboard"))
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    Text(url.host ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption)
            }
            .help(L("Official management page") + "\n" + url.absoluteString)
            .accessibilityIdentifier("provider-dashboard")
        }
    }
}
