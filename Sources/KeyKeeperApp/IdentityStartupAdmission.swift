import AppKit
import SwiftUI
import KeyKeeperCore

/// The only entry into the new vault. No business store is created before admission.
///
/// 2026-11-05: a first install used to be shown as "move your old data", because every
/// `.required` status shared the migration screen. Before the person confirms anything, only the
/// old folder's file names are looked at (no file contents, no Keychain), so the screen says what
/// is there: nothing (first install), old data (copy, originals kept), or a folder that could not
/// be checked (stop, never an empty store). The full, secret-bearing read happens only after the
/// person confirms, and the write is bound to what they confirmed (main-Mac acceptance R1/R2).
@MainActor
final class IdentityStartupAdmission: ObservableObject {
    struct Operations {
        let status: () throws -> IdentityMigrationStatus
        let recover: () throws -> Void
        let applyPreferences: () throws -> Void
        /// Names only: does the old KeyKeeper folder hold anything? Never reads contents or Keychain.
        let legacyFilesExist: () throws -> Bool
        /// The full old source, values included. Called only from `prepare()`, after confirmation.
        let readSource: () async throws -> IdentityMigrationSource
        /// The first write, refused by the coordinator if the source is not the confirmed kind.
        let migrate: (_ source: IdentityMigrationSource, _ expectedLegacyData: Bool) throws -> Void
    }

    enum Stage: Equatable {
        case checking
        case firstInstall
        case legacyFound
        case preparing
        case failed(Failure)
    }

    struct Failure: Equatable {
        enum Kind: Equatable {
            /// The old store could not be read. Nothing was written, no empty store replaces it.
            case sourceUnreadable
            /// The old store was read but cannot be copied safely by this version.
            case unsupported
            /// The new store could not be written or verified. Existing data is kept.
            case storage
        }
        let kind: Kind
        /// Fixed, translated vocabulary only; never an OS, path or source diagnostic.
        let detail: String?
    }

    @Published private(set) var stage: Stage = .checking
    /// The confirmed screen no longer matched what was read; nothing was written and the person
    /// is asked again on the screen that matches.
    @Published private(set) var sourceChangedSinceConfirmation = false
    private(set) var admitted = false
    private var busy = false
    private let operations: Operations
    private let onReady: () -> Void

    init(operations: Operations, onReady: @escaping () -> Void) {
        self.operations = operations; self.onReady = onReady
    }

    static func production(onReady: @escaping () -> Void) -> IdentityStartupAdmission {
        let coordinator = IdentityMigrationCoordinator.production()
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeyKeeperMigrationBridge")
        return .init(operations: .init(
            status: { try coordinator.status() },
            recover: { _ = try coordinator.recover() },
            applyPreferences: { try coordinator.applyPreferences() },
            legacyFilesExist: { try IdentityMigrationLegacyCapture.legacyFilesExist() },
            readSource: { try await IdentityMigrationBridge.read(from: helper) },
            migrate: { source, expected in
                _ = try coordinator.migrate(source: source, expectedLegacyData: expected)
            }), onReady: onReady)
    }

    /// Finishes an interrupted copy or admits a ready store; otherwise shows the screen that
    /// matches the old folder. Never reads the old source.
    func start() {
        guard !admitted, !busy else { return }
        stage = .checking
        do {
            if try checkpoint() { return }
        } catch {
            fail(error, during: .storage)
            return
        }
        do {
            stage = try operations.legacyFilesExist() ? .legacyFound : .firstInstall
        } catch { fail(error, during: .sourceUnreadable) }
    }

    func retry() {
        if case .failed = stage { sourceChangedSinceConfirmation = false; start() }
    }

    /// The person confirmed the screen they saw: set up an empty store, or copy the old data.
    func prepare() async {
        guard !admitted, !busy else { return }
        let expectLegacy: Bool
        switch stage {
        case .firstInstall: expectLegacy = false
        case .legacyFound: expectLegacy = true
        default: return
        }
        busy = true; stage = .preparing; sourceChangedSinceConfirmation = false
        defer { busy = false }
        do {
            // A pending journal is already a confirmed source; never read a second source.
            if try operations.status() == .required {
                let source: IdentityMigrationSource
                do { source = try await operations.readSource() } catch {
                    fail(error, during: .sourceUnreadable); return
                }
                guard source.hasLegacyData == expectLegacy else {
                    // Not what was confirmed: write nothing and ask on the screen that matches.
                    sourceChangedSinceConfirmation = true
                    stage = source.hasLegacyData ? .legacyFound : .firstInstall
                    return
                }
                try operations.migrate(source, expectLegacy)
            }
            if try !checkpoint() { throw IdentityMigrationError.unavailable }
        } catch { fail(error, during: .storage) }
    }

    /// Returns true once admitted. Only a store that reads back as ready is admitted.
    private func checkpoint() throws -> Bool {
        if try operations.status() == .pending { try operations.recover() }
        guard try operations.status() == .ready else { return false }
        try operations.applyPreferences()
        admitted = true
        onReady()
        return true
    }

    private func fail(_ error: Error, during kind: Failure.Kind) {
        stage = .failed(Self.failure(for: error, during: kind))
    }

    static func failure(for error: Error, during kind: Failure.Kind) -> Failure {
        let migration = error as? IdentityMigrationError
        let resolved: Failure.Kind
        switch migration {
        case .unsignedMetadata, .malformed: resolved = .unsupported
        // Reading the old store failed (also when it happens at the copy): nothing was written.
        case .legacyRunning, .identity, .activeImport, .sourceChanged: resolved = .sourceUnreadable
        default: resolved = kind
        }
        return .init(kind: resolved, detail: migration?.errorDescription.map { AppL10n.text($0) })
    }
}

struct IdentityStartupView: View {
    @ObservedObject var admission: IdentityStartupAdmission
    @AppStorage(AppL10n.preferenceName) private var interfaceLanguage = "system"

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "key.fill").font(.title3).foregroundStyle(.tint)
                Text("KeyKeeper").font(.title2.bold())
                Spacer()
                LanguageMenu(selection: $interfaceLanguage)
            }
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                if admission.sourceChangedSinceConfirmation {
                    Text(L("The earlier KeyKeeper’s data on this Mac changed after you confirmed. Nothing was written. Check this screen and confirm again."))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                content
            }
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            HStack {
                Button(L("Quit KeyKeeper")) { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Spacer()
                primaryButton
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.locale, AppL10n.locale(preference: interfaceLanguage))
    }

    @ViewBuilder private var content: some View {
        switch admission.stage {
        case .checking:
            progress(L("Checking this Mac…"))
        case .preparing:
            progress(L("Preparing this Mac…"))
        case .firstInstall:
            title(L("First, set up this Mac"))
            paragraph(L("KeyKeeper keeps your keys in protected storage on this Mac. Nothing is uploaded."))
            note(L("iCloud sync stays off. You can turn it on later in Settings."))
        case .legacyFound:
            title(L("Copy data from the earlier KeyKeeper"))
            paragraph(L("This Mac has data from an earlier version of KeyKeeper. It will be copied into the new protected storage; the originals stay where they are."))
            note(L("Values that were already missing stay marked as missing; copying cannot recover them."))
            note(L("Approvals are not copied. Each agent asks you again the first time it uses a key."))
            note(L("iCloud sync stays off. You can turn it on later in Settings."))
        case .failed(let failure):
            title(Self.failureTitle(failure.kind))
            paragraph(Self.failureBody(failure.kind))
            if let detail = failure.detail { note(detail) }
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch admission.stage {
        case .firstInstall:
            Button(L("Set Up")) { Task { await admission.prepare() } }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        case .legacyFound:
            Button(L("Copy and Continue")) { Task { await admission.prepare() } }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        case .failed:
            Button(L("Try Again")) { admission.retry() }.keyboardShortcut(.defaultAction)
        case .checking, .preparing:
            EmptyView()
        }
    }

    static func failureTitle(_ kind: IdentityStartupAdmission.Failure.Kind) -> String {
        switch kind {
        case .sourceUnreadable: L("Could not read the earlier KeyKeeper’s data")
        case .unsupported: L("This Mac’s data can’t be copied automatically yet")
        case .storage: L("This Mac could not be set up")
        }
    }

    static func failureBody(_ kind: IdentityStartupAdmission.Failure.Kind) -> String {
        switch kind {
        case .sourceUnreadable: L("Nothing was changed, and no empty store was created in its place.")
        case .unsupported: L("The originals are unchanged.")
        case .storage: L("Existing data was kept. If setup was interrupted, trying again continues from where it stopped.")
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
    private func title(_ text: String) -> some View { Text(text).font(.headline) }
    private func paragraph(_ text: String) -> some View {
        Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The App's own language choice, reachable before anything else is set up.
struct LanguageMenu: View {
    @Binding var selection: String
    var body: some View {
        // Compact: the page itself already shows the current language; the menu marks it too.
        Menu {
            Picker(L("Language"), selection: $selection) {
                Text(L("Follow system")).tag("system")
                Text("简体中文").tag("zh-Hans")
                Text("English").tag("en")
            }
            .pickerStyle(.inline)
        } label: {
            Label("中文 / English", systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .help(L("Language"))
        .accessibilityLabel(L("Language"))
    }
}
