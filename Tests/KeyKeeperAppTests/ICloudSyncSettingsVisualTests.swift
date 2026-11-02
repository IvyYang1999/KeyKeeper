import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

/// Background snapshots of production views; no window, cloud service or real data.
@MainActor
final class ICloudSyncSettingsVisualTests: XCTestCase {
    func testSyntheticSettingsAndReviewOffscreen() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_ICLOUD_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic iCloud settings render; no native window")
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let review = ICloudSyncPresentation.ConflictReview(id: UUID(), rows: [
            .init(id: "synthetic-api", label: "Synthetic development API with a deliberately long credential name",
                  localExists: true, remoteExists: true, localUpdated: "2026-11-02 10:00", remoteUpdated: "2026-11-02 09:00"),
            .init(id: "synthetic-deleted", label: "Synthetic removed credential", localExists: true, remoteExists: false)
        ])
        let layouts: [(String, Double, Bool)] = [
            ("zh-Hans", 320, true), ("en", 600, false), ("en", 320, true), ("zh-Hans", 600, false)
        ]
        for (language, width, dark) in layouts {
            defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)
            let name = "\(language)-\(Int(width))-\(dark ? "dark" : "light")"
            let states: [ICloudSyncPresentation] = [
                .init(),
                .init(phase: .ready, enabled: true, lastSuccess: Date(timeIntervalSince1970: 1_793_600_000)),
                .init(phase: .paused, enabled: true, issue: .pendingUpload),
                .init(phase: .conflict, enabled: true, review: review),
                .init(phase: .migrationRequired)
            ]
            let stack = VStack(spacing: 12) {
                ForEach(states.indices, id: \.self) { index in
                    ICloudSyncSettingsCard(state: states[index], action: { _ in XCTFail("Rendering must not perform actions") })
                }
            }
            try render(stack.padding(12), width: width, dark: dark, name: "cards-" + name, output: output, maximumHeight: 1800)
        }
        defaults.setVolatileDomain([AppL10n.preferenceName: "zh-Hans"], forName: UserDefaults.argumentDomain)
        try render(ICloudSyncConfirmation(kind: .enable, action: { _ in XCTFail("Render must not enable") }),
            width: 320, dark: true, name: "enable-zh-small", output: output, maximumHeight: 600)
        defaults.setVolatileDomain([AppL10n.preferenceName: "en"], forName: UserDefaults.argumentDomain)
        try render(ICloudSyncConfirmation(kind: .migrate, action: { _ in XCTFail("Render must not migrate") }),
            width: 320, dark: false, name: "migration-en-small", output: output, maximumHeight: 600)
        try render(ICloudSyncConflictSheet(review: review, currentReviewID: review.id,
            action: { _ in XCTFail("Unselected review must not resolve") }), width: 320, dark: false,
            name: "review-en-small", output: output, maximumHeight: 600)
        try render(ICloudSyncConflictSheet(review: review, currentReviewID: UUID(), action: { _ in XCTFail("Stale review must not resolve") }),
            width: 600, dark: true, name: "review-stale-wide", output: output, maximumHeight: 600)
        defaults.setVolatileDomain([AppL10n.preferenceName: "zh-Hans"], forName: UserDefaults.argumentDomain)
        let startupCases: [(String, IdentityMigrationError?)] = [("required", nil), ("old-running", .legacyRunning)]
        for (name, error) in startupCases {
            let admission = IdentityStartupAdmission(operations: .init(
                status: { if let error { throw error }; return .required }, recover: { XCTFail() },
                applyPreferences: { XCTFail() }, migrate: { XCTFail() }), onReady: { XCTFail() })
            admission.start()
            try render(IdentityStartupView(admission: admission), width: 460, dark: true,
                       name: "startup-" + name, output: output, maximumHeight: 700)
        }
    }

    private func render<Content: View>(_ content: Content, width: Double, dark: Bool,
                                       name: String, output: String, maximumHeight: Double) throws {
        let view = NSHostingView(rootView: content
            .frame(width: width).environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, width, accuracy: 1, "Content cannot widen its assigned column")
        XCTAssertGreaterThan(view.fittingSize.height, 80)
        XCTAssertLessThan(view.fittingSize.height, maximumHeight)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("icloud-\(name).png"))
    }
}
