import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

/// Opt-in contact sheet for the exact 32pt list tile and 18pt inline mark used by the app.
/// Synthetic catalog metadata only; no credentials or user data are loaded.
@MainActor final class ProviderMarksVisualTests: XCTestCase {
    func testRenderEveryProviderMarkInLightAndDarkMode() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_PROVIDER_MARKS_PREVIEW"] else {
            throw XCTSkip("Opt-in visual inspection, catalog metadata only")
        }
        _ = NSApplication.shared

        for (name, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            let root = ProviderMarksContactSheet()
                .environment(\.colorScheme, scheme)
                .padding(20)
                .frame(width: 760)
                .background(Color(nsColor: .windowBackgroundColor))
            let view = NSHostingView(rootView: root)
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()

            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("provider-marks-\(name).png"))
            XCTAssertGreaterThan(view.fittingSize.height, 500)
        }
    }
}

private struct ProviderMarksContactSheet: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(ProviderCatalog.all) { provider in
                HStack(spacing: 9) {
                    KeyAvatar(label: provider.name, kind: .provider(provider.id), size: 32)
                    ProviderMark(providerId: provider.id, size: 18, colored: true)
                    Text(provider.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
