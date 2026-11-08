import SwiftUI
import KeyKeeperCore

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

    /// "sk_live_abc123def456" → "•••• f456"; a short value shows dots only.
    static func mask(_ text: String) -> String { ValueHintText.masked(ValueHint.suffix(of: text)) }
}

/// How a secret looks wherever it is not revealed: dots, then its last four characters when
/// it is long enough to have them (用户 2026-11-08 定「显示后 4 位」).
enum ValueHintText {
    static let dots = "\u{2022}\u{2022}\u{2022}\u{2022}"

    static func masked(_ hint: String?) -> String {
        hint.map { "\(dots) \($0)" } ?? dots + dots
    }

    /// A list row's field names, followed by the one secret's last four characters when the
    /// key has exactly one secret: two "OpenAI" keys stop looking the same.
    static func listSubtitle(_ summary: String, credential: Credential, hints: [String: String]) -> String {
        let secrets = credential.fields.filter { $0.value.secret && $0.value.fileFormat == nil }.map(\.key)
        guard secrets.count == 1, let hint = hints[secrets[0]] else { return summary }
        return "\(summary) \u{00B7} \(masked(hint))"
    }
}

/// Displays a secret value as masked text (dots and its last four characters).
/// Provides eye toggle and copy button. Typing happens in a SecureField (dots), so
/// nothing is ever shown in the clear unless the eye is clicked; the eye is the only
/// thing that reveals or hides. (An earlier "mask on focus loss" rule raced with the
/// SecureField→TextField swap on the eye click and immediately re-hid the value.)
struct MaskedValueField: View {
    @Binding var value: String
    @Binding var visible: Bool
    var placeholder: String = L("Paste or type the value")
    var editable: Bool = true
    var onCopy: (() -> Void)?
    /// Put the cursor in the field as soon as it appears (replacing a saved value).
    var focusOnAppear = false
    /// Replaces the plain visible toggle, e.g. to fetch a stored value before revealing it.
    var onToggleVisibility: (() -> Void)?

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
                .textFieldStyle(.plain)
                .textContentType(.none)
                .font(.callout.monospaced())
                .focused($isFocused)
            } else {
                Text(MaskedFieldPresentation.mask(value))
                    .font(.callout.monospaced())
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if editable {
                            visible = true
                            isFocused = true
                        }
                    }
                    .help(editable ? L("Click to edit") : "")
            }

            Button(action: {
                if let onToggleVisibility { onToggleVisibility() } else { visible.toggle() }
                if visible, editable {
                    // The control is swapped (SecureField → TextField); focus it once the new one exists.
                    DispatchQueue.main.async { isFocused = true }
                }
            }) {
                // The eye says what a click does: show (eye) while hidden, hide (eye.slash) while shown.
                Image(systemName: visible ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(visible ? L("Hide value") : L("Show value"))

            if onCopy != nil {
                Button(action: { onCopy?() }) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(L("Copy value"))
            }
        }
        .onAppear {
            if focusOnAppear { DispatchQueue.main.async { isFocused = true } }
        }
    }
}

/// "Search 6 keys", and "Search 1 key" rather than "Search 1 keys".
enum KeySearchPlaceholder {
    static func text(count: Int) -> String {
        count == 1 ? L("Search 1 key") : L("Search \(count) keys")
    }
}
