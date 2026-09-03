import SwiftUI

/// Pure presentation rules for `MaskedValueField`, kept out of the view so they can be unit tested.
enum MaskedFieldPresentation {
    /// Whether the editable text control (instead of the masked label) should be on screen.
    ///
    /// The control must stay mounted for as long as it has keyboard focus. Masking is only
    /// allowed once focus leaves the field; deciding it from the value alone swapped the
    /// control out after the first typed character and made manual entry impossible.
    static func showsTextField(
        editable: Bool,
        revealed: Bool,
        valueIsEmpty: Bool,
        isFocused: Bool
    ) -> Bool {
        guard editable else { return false }
        return revealed || valueIsEmpty || isFocused
    }

    /// "sk_live_abc123def456" → "sk***56"
    static func mask(_ text: String) -> String {
        guard text.count > 4 else { return "***" }
        let prefix = String(text.prefix(2))
        let suffix = String(text.suffix(2))
        return "\(prefix)***\(suffix)"
    }
}

/// Displays a secret value as masked text (first 2 + last 2, middle as ***).
/// Provides eye toggle and copy button. Typing happens in a SecureField (dots), so
/// nothing is ever shown in the clear unless the eye is clicked; the eye is the only
/// thing that reveals or hides. (An earlier "mask on focus loss" rule raced with the
/// SecureField→TextField swap on the eye click and immediately re-hid the value.)
struct MaskedValueField: View {
    @Binding var value: String
    @Binding var visible: Bool
    var placeholder: String = "Paste or type the value"
    var editable: Bool = true
    var onCopy: (() -> Void)?

    @FocusState private var isFocused: Bool

    private var showTextField: Bool {
        MaskedFieldPresentation.showsTextField(
            editable: editable,
            revealed: visible,
            valueIsEmpty: value.isEmpty,
            isFocused: isFocused
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            if showTextField {
                Group {
                    if visible {
                        TextField(placeholder, text: $value)
                    } else {
                        SecureField(placeholder, text: $value)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .textContentType(.none)
                .font(.callout.monospaced())
                .focused($isFocused)
            } else {
                Text(MaskedFieldPresentation.mask(value))
                    .font(.callout.monospaced())
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(DS.Radius.sm)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .onTapGesture {
                        if editable {
                            visible = true
                            isFocused = true
                        }
                    }
                    .help(editable ? "Click to edit" : "")
            }

            Button(action: {
                visible.toggle()
                if visible, editable {
                    // The control is swapped (SecureField → TextField); focus it once the new one exists.
                    DispatchQueue.main.async { isFocused = true }
                }
            }) {
                Image(systemName: visible ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(visible ? "Hide value" : "Show value")

            if onCopy != nil {
                Button(action: { onCopy?() }) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help("Copy value")
            }
        }
    }
}
