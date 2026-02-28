import SwiftUI

/// Displays a secret value as masked text (first 2 + last 2, middle as ***).
/// Provides eye toggle and copy button.
struct MaskedValueField: View {
    @Binding var value: String
    @Binding var visible: Bool
    var placeholder: String = "Paste value here"
    var editable: Bool = true
    var onCopy: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if visible && editable {
                TextField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.none)
                    .font(.callout.monospaced())
            } else {
                Text(displayText)
                    .font(.callout.monospaced())
                    .foregroundColor(value.isEmpty ? .secondary.opacity(0.5) : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .onTapGesture {
                        if editable { visible = true }
                    }
            }

            Button(action: { visible.toggle() }) {
                Image(systemName: visible ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)

            if onCopy != nil {
                Button(action: { onCopy?() }) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var displayText: String {
        if value.isEmpty { return placeholder }
        return Self.mask(value)
    }

    /// "sk_live_abc123def456" → "sk***56"
    static func mask(_ text: String) -> String {
        guard text.count > 4 else { return "***" }
        let prefix = String(text.prefix(2))
        let suffix = String(text.suffix(2))
        return "\(prefix)***\(suffix)"
    }
}
