import XCTest
import AppKit
import SwiftUI
import KeyKeeperCore
@testable import KeyKeeperApp

@MainActor
final class NativeSettingsRootTests: XCTestCase {
    /// 【曾经的 bug】系统 Settings 场景是 EmptyView，服务已就绪也只有空白窗口。
    func testReadyBuildsVisibleSettingsContent() {
        var builds = 0
        let root = NativeSettingsRoot(phase: .ready) {
            builds += 1
            return VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.title2.bold())
                ICloudSyncSettingsCard(state: .init(), action: { _ in XCTFail() })
            }.padding(24).frame(width: 560)
        }
        assertVisible(root)
        XCTAssertGreaterThan(builds, 0)
    }

    /// SettingsView 的初始化有存储依赖；门禁必须在构造它之前生效。
    func testStartingIsVisibleWithoutConstructingBusinessSettings() {
        var builds = 0
        let root = NativeSettingsRoot(phase: .starting) {
            builds += 1
            return Text("Must not construct")
        }
        assertVisible(root)
        XCTAssertEqual(builds, 0)
    }

    func testMigrationAndFailureStayVisibleWithoutConstructingBusinessSettings() {
        let admission = IdentityStartupAdmission(operations: .init(
            status: { throw IdentityMigrationError.unavailable },
            recover: { XCTFail() }, applyPreferences: { XCTFail() },
            migrate: { XCTFail() }), onReady: { XCTFail() })
        var builds = 0
        let root = NativeSettingsRoot(phase: .migration(admission)) {
            builds += 1
            return Text("Must not construct")
        }
        assertVisible(root)
        admission.start()
        assertVisible(root)
        XCTAssertEqual(builds, 0)
        XCTAssertFalse(admission.admitted)
    }

    func testSameObservedRootRefreshesAfterMigrationAdmission() async {
        let model = PhaseModel()
        var builds = 0
        var migrationStatus = IdentityMigrationStatus.required
        let admission = IdentityStartupAdmission(operations: .init(
            status: { migrationStatus }, recover: { XCTFail() }, applyPreferences: {},
            migrate: { migrationStatus = .ready }), onReady: { model.phase = .ready })
        let renderer = ImageRenderer(content: ObservedRoot(model: model) {
            builds += 1
            return Text("Synthetic settings after admission").padding(24)
        })
        XCTAssertNotNil(renderer.cgImage)
        XCTAssertEqual(builds, 0)
        model.phase = .migration(admission)
        admission.start()
        await Task.yield()
        XCTAssertNotNil(renderer.cgImage)
        XCTAssertEqual(builds, 0)
        XCTAssertFalse(admission.admitted)
        await admission.migrateConfirmed()
        await Task.yield()
        XCTAssertTrue(admission.admitted)
        XCTAssertNotNil(renderer.cgImage)
        XCTAssertGreaterThan(builds, 0)
    }

    private final class PhaseModel: ObservableObject {
        @Published var phase: NativeSettingsPhase = .starting
    }

    private struct ObservedRoot<Content: View>: View {
        @ObservedObject var model: PhaseModel
        let makeSettings: () -> Content
        var body: some View {
            NativeSettingsRoot(phase: model.phase, makeSettings: makeSettings)
        }
    }

    private func assertVisible<V: View>(_ view: V, file: StaticString = #filePath, line: UInt = #line) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        guard let image = renderer.cgImage else {
            XCTFail("Settings entry must render visible content", file: file, line: line)
            return
        }
        XCTAssertGreaterThan(image.width, 20, file: file, line: line)
        XCTAssertGreaterThan(image.height, 20, file: file, line: line)
        if let output = ProcessInfo.processInfo.environment["KEYKEEPER_NATIVE_SETTINGS_PREVIEW"] {
            let bitmap = NSBitmapImageRep(cgImage: image)
            do {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("native-settings-\(line).png"))
            } catch { XCTFail("Could not save synthetic preview", file: file, line: line) }
        }
    }
}
