import SwiftUI

enum NativeSettingsPhase {
    case starting
    case migration(IdentityStartupAdmission)
    case ready
}

/// Native Settings is a real entry point, independent of the custom Settings menu.
struct NativeSettingsRoot<Content: View>: View {
    @AppStorage(AppL10n.preferenceName) private var interfaceLanguage = "system"
    let phase: NativeSettingsPhase
    @ViewBuilder var makeSettings: () -> Content

    var body: some View {
        Group {
            switch phase {
            case .starting:
                VStack(spacing: DS.Spacing.lg) {
                    Text("KeyKeeper").font(.title2.bold())
                    ProgressView()
                }
                .padding(DS.Spacing.xl)
                .frame(width: 460, height: 180)
            case .migration(let admission):
                IdentityStartupView(admission: admission)
            case .ready:
                // SettingsView initializes storage-backed services. Keep construction
                // behind admission, rather than hiding an already-created view.
                makeSettings()
            }
        }
        .environment(\.locale, AppL10n.locale(preference: interfaceLanguage))
    }
}
