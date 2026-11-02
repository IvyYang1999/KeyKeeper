import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

@MainActor
final class StorageAdmissionVisualTests: XCTestCase {
    func testLastKnownListAndRetryWithSyntheticStorageOffscreen() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_ADMISSION_PREVIEW"] else {
            throw XCTSkip("Opt-in background synthetic metadata admission preview")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output).appendingPathComponent("fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let integrity = FakeKeychainIO()
        let store = MetaStore(directory: directory, integrityIO: integrity)
        let values = FakeKeychainIO()
        let service = KeychainCredentialService(store: KeychainBlobStore(io: values))
        let fixture = Credential(label: "Synthetic API", notes: "", links: [],
            fields: ["api-key": .init(secret: true)], security: .strict,
            created: "2026-11-02", updated: "2026-11-02")
        try service.save(credentialId: "synthetic", fieldName: "api-key", value: "synthetic-only", security: .strict)
        try store.save(MetaFile(credentials: ["synthetic": fixture]))
        let model = CredentialListViewModel(session: service, store: store)
        model.load()
        XCTAssertNil(model.loadFailure)
        XCTAssertEqual(model.credentials.count, 1)
        let key = integrity.blob
        integrity.blob = nil
        model.load()
        XCTAssertNotNil(model.loadFailure)
        XCTAssertEqual(model.credentials.count, 1)
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["en", "zh-Hans"] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)
            for width in [320.0, 460.0] {
                for dark in [false, true] {
                    try render(model, width: width, dark: dark,
                        name: "\(language)-\(Int(width))-\(dark ? "dark" : "light")", output: output)
                }
            }
        }
        integrity.blob = key
        model.load() // Same retry callback supplied to the production notice.
        XCTAssertNil(model.loadFailure)
        XCTAssertEqual(model.credentials.count, 1)
        try render(model, width: 320, dark: true, name: "recovered", output: output)
    }

    private func render(_ model: CredentialListViewModel, width: Double, dark: Bool,
                        name: String, output: String) throws {
        let view = NSHostingView(rootView: AdmissionPreviewList(model: model)
            .padding(12).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        XCTAssertLessThan(view.fittingSize.height, 500)
        XCTAssertGreaterThan(view.fittingSize.height, 50)
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("admission-\(name).png"))
    }
}

private struct AdmissionPreviewList: View {
    @ObservedObject var model: CredentialListViewModel
    var body: some View {
        VStack(spacing: 12) {
            if let failure = model.loadFailure {
                CredentialListFailureNotice(reason: failure.reason, hasLastKnownRows: !model.credentials.isEmpty,
                                            retry: model.load)
            }
            ForEach(model.credentials, id: \.id) { item in
                PopoverKeyRow(credential: item.credential, subtitle: "api-key", valueAvailability: .init(state: .unchecked)) {}
                    .disabled(model.loadFailure != nil)
            }
        }
    }
}
