import SwiftUI
import KeyKeeperCore

/// Looks like a pop-up button, opens the brand picker. Browsing never writes; only a pick does.
struct ProviderPickerButton: View {
    @Binding var selection: String
    @State private var isPresented = false

    private var provider: ProviderTemplate? { ProviderCatalog.find(selection) }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 6) {
                if let provider {
                    ProviderMark(providerId: provider.id, size: 15, colored: true)
                    Text(ProviderBrowser.family(containing: provider.id).map { family in
                        family.isSingle ? family.name : family.name + " · " + family.variantLabel(provider)
                    } ?? provider.name)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(selection.isEmpty ? L("Choose provider") : selection).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
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
    @State private var expanded: Set<String> = []
    @State private var highlightedID: String?
    @Environment(\.dismiss) private var dismiss

    init(selectedID: String, query: String = "", onSelect: @escaping (String) -> Void) {
        self.selectedID = selectedID
        self.onSelect = onSelect
        _query = State(initialValue: query)
    }

    private var rows: [ProviderPickerRow] { ProviderBrowser.rows(query: query, category: category, expanded: expanded) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderSearchField(text: $query, onMove: { delta in
                highlightedID = ProviderBrowser.movedHighlight(highlightedID, by: delta, in: rows)
            }, onSubmit: { activateHighlighted() }, onCancel: { dismiss() })
                .frame(height: 30)
            Picker(L("All categories"), selection: $category) {
                Text(L("All categories")).tag(nil as ProviderCategory?)
                ForEach(ProviderCategory.allCases) { category in
                    Text(category.title).tag(Optional(category))
                }
            }
            .labelsHidden().frame(maxWidth: 220, alignment: .leading)
            .accessibilityIdentifier("provider-category")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if rows.isEmpty {
                            VStack(spacing: 6) {
                                Text(L("No matching providers")).font(.headline)
                                Text(L("Try another name or category.")).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 44)
                            .accessibilityIdentifier("provider-empty")
                        }
                        ForEach(rows) { row in
                            ProviderPickerRowView(row: row, selectedID: selectedID,
                                                  highlighted: row.id == highlightedID) { activate(row) }
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: highlightedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !selectedID.isEmpty {
                Divider()
                HStack {
                    Spacer()
                    Button(L("Unbind provider")) { onSelect("") }
                        .font(.caption).buttonStyle(.borderless)
                }
            }
        }
        .padding(14)
        .frame(width: 430, height: 500)
        .onAppear {
            if let family = ProviderBrowser.family(containing: selectedID), !family.isSingle {
                expanded.insert(family.id)
            }
            let current = "template:" + selectedID
            highlightedID = rows.contains(where: { $0.id == current }) ? current : rows.first?.id
        }
        // While searching, Return should pick a key, not fold the brand it sits under.
        .onChange(of: query) { _, _ in highlightedID = (rows.first { $0.template != nil } ?? rows.first)?.id }
        .onChange(of: category) { _, _ in highlightedID = rows.first?.id }
        .onExitCommand { dismiss() }
    }

    private func activateHighlighted() {
        if let row = rows.first(where: { $0.id == highlightedID }) { activate(row) }
    }

    /// A brand row opens or closes; only a template row binds.
    private func activate(_ row: ProviderPickerRow) {
        switch row {
        case .family(let family, _, let open):
            if open { expanded.remove(family.id) } else { expanded.insert(family.id) }
            highlightedID = row.id
        case .template(let template, _, _, _):
            onSelect(template.id)
        }
    }
}

/// A mark on a quiet tile, so lettermarks, glyphs and full-colour icons line up as one column.
struct ProviderTile: View {
    let providerId: String
    var size: CGFloat = 30
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ProviderMark(providerId: providerId, size: size * 0.6, colored: true)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

private struct ProviderPickerRowView: View {
    let row: ProviderPickerRow
    let selectedID: String
    let highlighted: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                switch row {
                case .family(let family, let matched, let open):
                    ProviderTile(providerId: family.markId)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(family.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(L("\(matched.count) options")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .accessibilityHidden(true)
                case .template(let template, let family, let nested, let variant):
                    if nested {
                        Color.clear.frame(width: 30, height: 1)
                    } else {
                        ProviderTile(providerId: template.id)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nested ? (variant ?? template.name)
                             : (variant.map { family.name + " · " + $0 } ?? family.name))
                            .font(.system(size: 13, weight: nested ? .regular : .medium))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(ProviderBrowser.environmentSummary(template))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                        .opacity(template.id == selectedID ? 1 : 0).accessibilityHidden(true)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((hovered || highlighted) ? Glass.fill(.raised, scheme) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(row.template?.id == selectedID ? .isSelected : [])
        .accessibilityIdentifier("provider-option-" + row.id)
    }

    private var accessibilityLabel: String {
        switch row {
        case .family(let family, let matched, _): return family.name + ", " + L("\(matched.count) options")
        case .template(let template, let family, _, let variant):
            return variant.map { family.name + " " + $0 } ?? template.name
        }
    }
}

/// One line to the provider's own page: the add flow points at where a key is created, the
/// detail page at where it is managed or rotated. Static https URLs only, nothing appended.
struct ProviderConsoleLink: View {
    enum Purpose { case create, manage }
    let providerID: String?
    var purpose: Purpose = .manage

    private var url: URL? {
        purpose == .create ? ProviderBrowser.createURL(for: providerID) : ProviderBrowser.managementURL(for: providerID)
    }

    var body: some View {
        if let url, let host = url.host {
            Link(destination: url) {
                HStack(spacing: 3) {
                    Text(purpose == .create ? L("Create the key at \(host)") : L("Manage at \(host)"))
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.caption)
            }
            .help(url.absoluteString)
            .accessibilityIdentifier("provider-dashboard")
        }
    }
}
