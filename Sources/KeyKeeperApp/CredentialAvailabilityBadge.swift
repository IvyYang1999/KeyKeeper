import SwiftUI
import KeyKeeperCore

/// A mark only when a value is missing. Not checked yet, checking, present, or not checkable
/// without a prompt all look the same: nothing, because there is nothing for you to do.
///
/// 【曾经的 bug】2026-11-07 yyt：菜单栏每行右边一个灰色「?」（还没检查值），7 行就是 7 个问号，像帮助按钮；
/// 详情页还有一整行「尚未检查值 / 重新检测」，把内部状态当成内容。
struct CredentialAvailabilityBadge: View {
    var availability: CredentialValueAvailability
    var compact = false

    static func isShown(_ availability: CredentialValueAvailability) -> Bool { availability.state == .missing }

    @ViewBuilder var body: some View {
        if Self.isShown(availability) {
            Group {
                if compact { Image(systemName: symbol).accessibilityLabel(title) }
                else { Label(title, systemImage: symbol) }
            }
            .font(.caption)
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .help(explanation)
        }
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
