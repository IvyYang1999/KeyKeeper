import SwiftUI
import KeyKeeperCore

struct CredentialAvailabilityBadge: View {
    var availability: CredentialValueAvailability
    var compact = false
    var body: some View {
        Group {
            if compact { Image(systemName: symbol).accessibilityLabel(title) }
            else { Label(title, systemImage: symbol) }
        }
            .font(.caption)
            .foregroundColor(availability.state == .missing ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(explanation)
    }
    private var explanation: String {
        switch availability.state {
        case .missing:
            return L("Missing fields: \(availability.missingFields.joined(separator: ", "))") + "\n" + L("The names were restored, but these values are absent from the current storage. Keep your old Keychain and backups. Restore the values or import replacements from the official provider; do not reset the Keychain.")
        case .unavailable:
            return L("Storage could not be checked without an authorization prompt. This does not mean the values are lost. No data was changed.")
        case .present:
            return L("Present in local storage at the last check. Provider validity and caller permission have not been verified.")
        case .unchecked: return title
        }
    }
    private var title: String {
        switch availability.state {
        case .unchecked: return L("Value not checked")
        case .present: return L("Local value present")
        case .missing: return L("Value missing · Recovery needed")
        case .unavailable: return L("Unable to check value")
        }
    }
    private var symbol: String {
        switch availability.state {
        case .unchecked: return "questionmark.circle"
        case .present: return "checkmark.circle"
        case .missing: return "exclamationmark.triangle"
        case .unavailable: return "questionmark.diamond"
        }
    }
}
