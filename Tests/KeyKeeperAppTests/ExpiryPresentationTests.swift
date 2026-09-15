import XCTest
import AppKit
import SwiftUI
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport


/// 过期日在 App 里：新建、编辑都能填；列表只在快过期和已过期时打标记。
@MainActor
final class ExpiryPresentationTests: XCTestCase {
    private var dir: URL!
    private var store: MetaStore!
    private var session: KeychainCredentialService!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("expiry-ui-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = MetaStore(directory: dir)
        let metadata = store!
        session = KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO(), loadMetadata: { try metadata.load() }))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func day(_ value: String) -> Date { CredentialExpiry.date(from: value)! }

    func test列表只在快过期和已过期时打标记() {
        let today = day("2026-09-13")
        XCTAssertNil(ExpiryPresentation.badge("2026-12-31", today: today))
        XCTAssertEqual(ExpiryPresentation.badge("2026-09-12", today: today)?.isExpired, true)
        XCTAssertEqual(ExpiryPresentation.badge("2026-09-20", today: today)?.isExpired, false)
        XCTAssertNil(ExpiryPresentation.badge(nil, today: today))
        XCTAssertNotNil(ExpiryPresentation.line("2026-12-31", today: today), "详情页总是写出日期")
    }

    func test新建和编辑都能记过期日() throws {
        let add = AddCredentialViewModel(session: session, store: store, approvals: .inMemory())
        add.label = "Synthetic"
        add.credentialId = "fixture"
        add.fields = [FieldEntry(name: "one", value: "synthetic")]
        add.expires = "2026-12-31"
        XCTAssertTrue(add.save(), add.errorMessage ?? "")
        let saved = try XCTUnwrap(store.load().credentials["fixture"])
        XCTAssertEqual(saved.expires, "2026-12-31")

        let detail = CredentialDetailViewModel(credentialId: "fixture", credential: saved, session: session, store: store, approvals: .inMemory())
        detail.credential.expires = "2027-01-31"
        XCTAssertTrue(detail.saveChanges(), detail.errorMessage ?? "")
        XCTAssertEqual(try store.load().credentials["fixture"]?.expires, "2027-01-31")
    }

    func test过期界面文案有中文() {
        for template in ["This key has an expiry date", "Last day it works", "Expired", "Last day today", "Expires tomorrow",
                         "Expires in {0} days", "Expired {0} · {1} days ago", "Last day it works: {0} · in {1} days",
                         "Copy it from the provider's page. KeyKeeper shows it here and tells agents once it has passed; it never blocks or deletes the key."] {
            XCTAssertNotEqual(AppL10n.render(template, language: "zh-Hans"), template, template)
        }
    }

    func test服务商规则与这把Key的实际日期是两个事实() throws {
        let policy = try XCTUnwrap(ProviderExpiryPolicyLine.text(providerId: "anthropic"))
        XCTAssertTrue(policy.contains("Anthropic"))
        XCTAssertTrue(policy.contains("3 hours"))
        XCTAssertEqual(ExpiryPresentation.line("2026-12-31", today: day("2026-09-15")),
                       "Last day it works: 2026-12-31 · in 107 days")
        XCTAssertNil(ProviderExpiryPolicyLine.text(providerId: nil))
    }

    func testRenderProviderPolicyAndRecordedDate() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_EXPIRY_PREVIEW"] else {
            throw XCTSkip("Opt-in visual inspection, synthetic expiry data only")
        }
        _ = NSApplication.shared
        let recorded = ExpiryPresentation.line("2026-12-31", today: day("2026-09-15"))!
        let root = VStack(alignment: .leading, spacing: 8) {
            ProviderExpiryPolicyLine(providerId: "anthropic")
            Label(recorded, systemImage: "calendar")
                .font(.callout)
        }
        .padding(16)
        .frame(width: 560, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("provider-expiry.png"))
    }
}

extension ExpiryPresentationTests {
    /// 主窗口的列表行是自己画的，不经过 CredentialRow——只改 CredentialRow，主窗口就看不到标记。
    func test主窗口列表也有过期标记() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/KeyKeeperApp/MainWindow.swift", "Sources/KeyKeeperApp/CredentialRow.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("ExpiryBadge(expires: credential.expires)"), file)
        }
    }
}
