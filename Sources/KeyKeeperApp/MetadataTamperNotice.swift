import SwiftUI

/// Shown above the credential list when meta.json fails KeyKeeper's signature check.
struct MetadataTamperNotice: View {
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Your credential list was changed outside KeyKeeper"), systemImage: "exclamationmark.shield")
                .font(.callout.weight(.semibold))
                .foregroundColor(.red)
            Text(L("Until you check it, KeyKeeper hands no keys to agents. Look through the list: titles, which fields are secret, plain values. If it is all as you left it, confirm and KeyKeeper will trust this version."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("It's all as I left it"), action: onConfirm)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.attention, radius: 10)
    }
}
