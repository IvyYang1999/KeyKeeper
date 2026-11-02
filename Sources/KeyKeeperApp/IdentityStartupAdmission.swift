import AppKit
import SwiftUI
import KeyKeeperCore

/// The only entry into the new vault. No business store is created before admission.
@MainActor
final class IdentityStartupAdmission: ObservableObject {
    struct Operations {
        let status: () throws -> IdentityMigrationStatus
        let recover: () throws -> Void
        let applyPreferences: () throws -> Void
        let migrate: () async throws -> Void
    }
    @Published private(set) var state = ICloudSyncPresentation(phase: .migrationRequired)
    @Published private(set) var failureNotice: String?
    private(set) var admitted = false
    private var busy = false
    private let operations: Operations
    private let onReady: () -> Void

    init(operations: Operations, onReady: @escaping () -> Void) {
        self.operations = operations; self.onReady = onReady
    }

    static func production(onReady: @escaping () -> Void) -> IdentityStartupAdmission {
        let coordinator = IdentityMigrationCoordinator.production()
        return .init(operations: .init(
            status: { try coordinator.status() },
            recover: { _ = try coordinator.recover() },
            applyPreferences: { try coordinator.applyPreferences() },
            migrate: {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeyKeeperMigrationBridge")
                let source = try await IdentityMigrationBridge.read(from: helper)
                _ = try coordinator.migrate(source: source)
            }), onReady: onReady)
    }

    func start() {
        guard !admitted, !busy else { return }
        do { try checkpoint() } catch { showFailure(error) }
    }

    func perform(_ action: ICloudSyncAction) {
        guard action == .migrate, !admitted, !busy else { return }
        Task { await migrateConfirmed() }
    }

    func migrateConfirmed() async {
        guard !admitted, !busy else { return }
        busy = true; failureNotice = nil; state = .init(phase: .syncing)
        defer { busy = false }
        do {
            // A pending journal is already a confirmed source; never read a second source.
            if try operations.status() == .required { try await operations.migrate() }
            try checkpoint()
        } catch { showFailure(error) }
    }

    private func checkpoint() throws {
        if try operations.status() == .pending { try operations.recover() }
        guard try operations.status() == .ready else {
            state = .init(phase: .migrationRequired); return
        }
        try operations.applyPreferences()
        admitted = true
        onReady()
    }

    private func showFailure(_ error: Error) {
        let unsupported: Bool
        switch error as? IdentityMigrationError {
        case .unsignedMetadata, .malformed: unsupported = true
        default: unsupported = false
        }
        state = .init(phase: .migrationRequired,
                      issue: unsupported ? .unsupportedMigration : .storageUnavailable)
        // Only our fixed error vocabulary is displayed, never an OS/path/source diagnostic.
        failureNotice = (error as? IdentityMigrationError)?.errorDescription.map { AppL10n.text($0) }
    }
}

struct IdentityStartupView: View {
    @ObservedObject var admission: IdentityStartupAdmission
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            Text("KeyKeeper").font(.title2.bold())
            ICloudSyncSettingsCard(state: admission.state, action: admission.perform)
            if let notice = admission.failureNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            Button(L("Quit KeyKeeper")) { NSApp.terminate(nil) }.font(.caption)
        }
        .padding(DS.Spacing.xl)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
