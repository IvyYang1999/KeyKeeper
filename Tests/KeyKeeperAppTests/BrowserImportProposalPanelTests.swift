import XCTest
import AppKit
import SwiftUI
import KeyKeeperCore
@testable import KeyKeeperApp

@MainActor
final class BrowserImportProposalPanelTests: XCTestCase {
    private func snapshot(_ state: BrowserImportProposalState) -> BrowserImportProposalSnapshot {
        .init(id: String(repeating: "a", count: 64), credentialId: "fixture", fieldName: "api-key",
              state: state, deadline: Date().addingTimeInterval(300), nextAction: "synthetic")
    }

    /// A recovered paste needs its own card. Once the native approval is visible, the existing
    /// ApprovalCenter card owns the interaction and the recovery card must not duplicate it.
    func testOnlyRecoveredPasteNeedsARecoveryCardAndBadge() {
        XCTAssertNotNil(BrowserImportProposalDisplay.recoverable(snapshot(.pasteReceived)))
        XCTAssertEqual(BrowserImportProposalDisplay.badgeCount(snapshot(.pasteReceived)), 1)

        for state in [BrowserImportProposalState.receiverReady, .approvalVisible, .committing,
                      .committed, .expired, .cancelled, .failed] {
            XCTAssertNil(BrowserImportProposalDisplay.recoverable(snapshot(state)), "state=\(state)")
            XCTAssertEqual(BrowserImportProposalDisplay.badgeCount(snapshot(state)), 0, "state=\(state)")
        }
    }

    func testExpiredRecoveredPasteIsNotActionableEvenBeforeTheTimerTicks() {
        var expired = snapshot(.pasteReceived)
        expired.deadline = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 101)
        XCTAssertNil(BrowserImportProposalDisplay.recoverable(expired, now: now))
        XCTAssertEqual(BrowserImportProposalDisplay.badgeCount(expired, now: now), 0)
    }

    func testRecoveryCardFitsTheRealPopoverWidthWithMaximumNames() {
        _ = NSApplication.shared
        var proposal = snapshot(.pasteReceived)
        proposal.credentialId = String(repeating: "c", count: 128)
        proposal.fieldName = String(repeating: "f", count: 128)
        let contentWidth = DS.Popover.width - 28
        let hosting = NSHostingView(rootView: BrowserImportProposalNotice(
            proposal: proposal, onReview: {}, onCancel: {}).frame(width: contentWidth))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, contentWidth, accuracy: 1)
        XCTAssertLessThan(hosting.fittingSize.height, 220, "Recovery must not consume the whole menu popover")
    }

    /// Opt-in synthetic visual fixture. It never opens the real vault or proposal Keychain.
    func testInteractiveRecoveryCard() throws {
        guard ProcessInfo.processInfo.environment["KEYKEEPER_BROWSER_PROPOSAL_UI_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in native interaction harness")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DS.Popover.width, height: 250),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "KeyKeeper · 浏览器导入恢复测试"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(spacing: 12) {
            BrowserImportProposalNotice(proposal: snapshot(.pasteReceived), onReview: {}, onCancel: {})
            Button("完成") { Self.stopApplicationLoop() }
        }
        .padding(14)
        .frame(width: DS.Popover.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: "zh-Hans")))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in
            MainActor.assumeIsolated { Self.stopApplicationLoop() }
        }
        defer { timer.invalidate(); window.close() }
        NSApp.run()
    }

    private static func stopApplicationLoop() {
        NSApp.stop(nil)
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: false)
        }
    }
}
