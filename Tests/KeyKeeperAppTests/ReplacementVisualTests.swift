import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

@MainActor final class ReplacementVisualTests: XCTestCase {
    func testRenderReplacementPromptWithSyntheticMetadata() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_REPLACEMENT_PREVIEW"] else {
            throw XCTSkip("Opt-in visual inspection, synthetic metadata only")
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["en", "zh-Hans"] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)
            let model = TrustPromptModel.save(.init(request: .init(credentialId: "signing-fixture",
                fieldName: "private-key", expect: "base64:32", replaceExisting: true), callerName: "Test Agent"))
            let view = NSHostingView(rootView: TrustPromptView(model: model, onCancel: {}, onConfirm: {}))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("replacement-\(language).png"))
            XCTAssertGreaterThan(view.fittingSize.height, 300)
            window.orderOut(nil)
        }
    }
}
