import SwiftUI
import KeyKeeperCore

/// Record the last day a key works at its provider. Optional, like notes.
struct ExpiryEditor: View {
    @Binding var expires: String?

    private var hasDate: Binding<Bool> {
        Binding(get: { expires != nil }, set: { on in
            if on {
                expires = expires ?? CredentialExpiry.string(
                    from: Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date())
            } else {
                expires = nil
            }
        })
    }

    private var day: Binding<Date> {
        Binding(get: { expires.flatMap(CredentialExpiry.date(from:)) ?? Date() },
                set: { expires = CredentialExpiry.string(from: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("This key has an expiry date"), isOn: hasDate)
            if expires != nil {
                DatePicker(L("Last day it works"), selection: day, displayedComponents: .date)
            }
            Text(L("Copy it from the provider's page. KeyKeeper shows it here and tells agents once it has passed; it never blocks or deletes the key."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Only when it matters: a badge on every row would stop meaning anything.
struct ExpiryBadge: View {
    let expires: String?

    var body: some View {
        if let badge = ExpiryPresentation.badge(expires) {
            Label(badge.label, systemImage: "calendar.badge.exclamationmark")
                .font(.caption2.weight(.medium))
                .foregroundColor(badge.isExpired ? .red : .orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((badge.isExpired ? Color.red : Color.orange).opacity(0.12), in: Capsule())
                .help(L("Last day it works: \(expires ?? "")"))
        }
    }
}

enum ExpiryPresentation {
    struct Badge: Equatable {
        let label: String
        let isExpired: Bool
    }

    static func badge(_ expires: String?, today: Date = Date()) -> Badge? {
        switch CredentialExpiry.status(of: expires, today: today) {
        case .expired: return Badge(label: L("Expired"), isExpired: true)
        case .expiresSoon(0): return Badge(label: L("Last day today"), isExpired: false)
        case .expiresSoon(1): return Badge(label: L("Expires tomorrow"), isExpired: false)
        case .expiresSoon(let days): return Badge(label: L("Expires in \(days) days"), isExpired: false)
        case .valid, nil: return nil
        }
    }

    /// For the detail page: always the date, and how far away it is.
    static func line(_ expires: String?, today: Date = Date()) -> String? {
        guard let expires, let status = CredentialExpiry.status(of: expires, today: today) else { return nil }
        switch status {
        case .expired(let days): return L("Expired \(expires) · \(days) days ago")
        case .expiresSoon(0): return L("Last day it works: \(expires) · today")
        case .expiresSoon(let days), .valid(let days): return L("Last day it works: \(expires) · in \(days) days")
        }
    }
}
