import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp

@MainActor final class ProviderBrowserVisualTests: XCTestCase {
    func test选择器浅深色完整边界() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_PROVIDER_BROWSER_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic UI snapshots")
        }
        _ = NSApplication.shared
        for (name, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)
        ] {
            let root = VStack(spacing: 0) {
                ProviderPickerView(selectedID: "openai", onSelect: { _ in })
                ProviderManagementLink(providerID: "openai").padding(14)
            }
            .environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor))
            let view = NSHostingView(rootView: root)
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("provider-browser-\(name).png"))
            XCTAssertEqual(view.bounds.width, 430)
            XCTAssertGreaterThan(view.bounds.height, 500)
        }
    }

    func test搜索框委托把方向与确认交给选择器不处理普通编辑() {
        var moves: [Int] = []
        var submits = 0
        var cancels = 0
        let search = ProviderSearchField(text: .constant(""), onMove: { moves.append($0) },
            onSubmit: { submits += 1 }, onCancel: { cancels += 1 })
        let delegate = search.makeCoordinator()
        let field = NSSearchField()
        let editor = NSTextView()
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertEqual(moves, [1, -1])
        XCTAssertEqual(submits, 1)
        XCTAssertEqual(cancels, 1)
    }
}
