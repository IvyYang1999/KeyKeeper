import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

/// Opt-in snapshots use synthetic metadata only. No production vault or Keychain reads.
@MainActor final class ApprovalReminderVisualTests: XCTestCase {
    func testRenderMissedRequestAndSoundSetting() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_APPROVAL_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic UI snapshots")
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let event = ServiceAuditEvent(timestamp: Date(), credentialId: "fixture-api", fieldName: "api-key",
            subjectFingerprint: "app:synthetic", subjectDisplayName: "Synthetic Agent", mode: .enforced,
            decision: "missed_approval", requestID: "synthetic-request")
        for (language, appearance) in [("zh-Hans", NSAppearance.Name.darkAqua), ("en", .aqua)] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language,
                                        ApprovalAlertPreferences.soundKey: false], forName: UserDefaults.argumentDomain)
            let root = VStack(alignment: .leading, spacing: 20) {
                MissedApprovalNotice(event: event, credentialLabel: "演示 API", count: 3,
                    loadFailed: false, recordFailed: false, onHistory: {}, onDismiss: { _ in }, onDismissWarning: {})
                ApprovalRemindersCard()
            }
            .padding(16).frame(width: 360)
            .environment(\.locale, AppL10n.locale(preference: language))
            .background(Color(nsColor: .windowBackgroundColor))
            let view = NSHostingView(rootView: root)
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("approval-reminders-\(language).png"))
            XCTAssertGreaterThan(view.fittingSize.height, 100)
        }
    }
}
