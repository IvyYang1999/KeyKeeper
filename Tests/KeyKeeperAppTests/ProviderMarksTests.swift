import XCTest
import AppKit
import CryptoKit
import SwiftUI
@testable import KeyKeeperApp
import KeyKeeperCore

/// yyt 2026-09-15：服务商和调用方要有 logo，一眼认出，别全是小字。
@MainActor
final class ProviderMarksTests: XCTestCase {
    private let auditedOfficialAssetDigests = [
        "volcengine-ark": "ee89e5e52cfbde8e91fd0e6f004607bab8345dcca86261dc907df0e76e96c50c",
        "azure": "54789c56a75c4f57f263bb8979479d8191cc852e77b0f6054c0ce36c5a7ea5bd",
        "aws": "5591807c1c7a961aad9843346816ab22d8173f8055bdd034b52ecf9e19c774c0",
        "app-store-connect": "7c0dd41fe59bd2a0992fb2b8ebc7dec82c2b84eef28ca3c5e496aa1b008ab2b7",
        "telegram": "9cce30f5c5a76639a84893e2788b278781e773aa45625f51c9f12ad4858cdc42",
        "posthog": "71b6788e362c91fde6c076a152545f792df51713ff61d84374ecaa58762049a3",
    ]

    private func assetDigest(for providerId: String) throws -> String {
        let mark = try XCTUnwrap(ProviderMarks.marks[providerId])
        let canonical = [
            mark.svgBody ?? "", mark.darkSVGBody ?? "", mark.pngBase64 ?? "",
            mark.systemSymbolName ?? "", mark.viewBox, mark.isTemplate ? "template" : "original",
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func raster<V: View>(_ content: V, scheme: ColorScheme = .light,
                                 appearance: NSAppearance.Name = .aqua,
                                 background: NSColor = .magenta) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let root = content
            .environment(\.colorScheme, scheme)
            .frame(width: 64, height: 64)
            .background(Color(nsColor: background))
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func signature(_ bitmap: NSBitmapImageRep, centerOnly: Bool = false) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bitmap.pixelsWide * bitmap.pixelsHigh * 4)
        let xs = centerOnly ? (bitmap.pixelsWide / 4)..<(bitmap.pixelsWide * 3 / 4) : 0..<bitmap.pixelsWide
        let ys = centerOnly ? (bitmap.pixelsHigh / 4)..<(bitmap.pixelsHigh * 3 / 4) : 0..<bitmap.pixelsHigh
        for y in ys {
            for x in xs {
                let color = (bitmap.colorAt(x: x, y: y) ?? .clear).usingColorSpace(.deviceRGB) ?? .clear
                result.append(UInt8((color.redComponent * 255).rounded()))
                result.append(UInt8((color.greenComponent * 255).rounded()))
                result.append(UInt8((color.blueComponent * 255).rounded()))
                result.append(UInt8((color.alphaComponent * 255).rounded()))
            }
        }
        return result
    }

    private func nonBackgroundPixelCount(_ bitmap: NSBitmapImageRep, background: NSColor) -> Int {
        let target = background.usingColorSpace(.deviceRGB) ?? background
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let distance = abs(color.redComponent - target.redComponent)
                    + abs(color.greenComponent - target.greenComponent)
                    + abs(color.blueComponent - target.blueComponent)
                if distance > 0.12 { count += 1 }
            }
        }
        return count
    }

    private func chromaticBuckets(_ bitmap: NSBitmapImageRep) -> Set<Int> {
        var buckets: Set<Int> = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5,
                      color.saturationComponent > 0.25 else { continue }
                let r = Int(color.redComponent * 7)
                let g = Int(color.greenComponent * 7)
                let b = Int(color.blueComponent * 7)
                buckets.insert((r << 6) | (g << 3) | b)
            }
        }
        return buckets
    }

    /// The middle half contains the mark, never the tile border or outer background.
    private func centerColorPixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in (bitmap.pixelsHigh / 4)..<(bitmap.pixelsHigh * 3 / 4) {
            for x in (bitmap.pixelsWide / 4)..<(bitmap.pixelsWide * 3 / 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5, color.saturationComponent > 0.25 else { continue }
                count += 1
            }
        }
        return count
    }

    private func whitePixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5, color.saturationComponent < 0.08,
                      color.brightnessComponent > 0.85 else { continue }
                count += 1
            }
        }
        return count
    }

    func test六个指定官方资产的字节摘要固定() throws {
        for (providerId, expected) in auditedOfficialAssetDigests {
            XCTAssertEqual(try assetDigest(for: providerId), expected, providerId)
        }
    }

    func test六个指定官方图在真实组件路径有像素_保留颜色_不受tint() throws {
        let providers = ["volcengine-ark", "azure", "aws", "app-store-connect", "telegram", "posthog"]
        for providerId in providers {
            let lightPlain = try raster(ProviderMark(providerId: providerId, size: 40, colored: false))
            let lightColored = try raster(ProviderMark(providerId: providerId, size: 40, colored: true))
            XCTAssertEqual(signature(lightPlain), signature(lightColored), "official \(providerId) artwork must ignore foreground tint")
            XCTAssertGreaterThan(nonBackgroundPixelCount(lightPlain, background: .magenta), 120, "\(providerId) must draw real pixels")
            XCTAssertGreaterThan(chromaticBuckets(lightPlain).count, 1, "\(providerId) must preserve provider colours")

            let darkPlain = try raster(ProviderMark(providerId: providerId, size: 40, colored: false),
                                       scheme: .dark, appearance: .darkAqua, background: .black)
            let darkColored = try raster(ProviderMark(providerId: providerId, size: 40, colored: true),
                                         scheme: .dark, appearance: .darkAqua, background: .black)
            XCTAssertEqual(signature(darkPlain), signature(darkColored), "dark \(providerId) artwork must ignore foreground tint")
            XCTAssertGreaterThan(nonBackgroundPixelCount(darkPlain, background: .black), 120, "dark \(providerId) must draw real pixels")
            if providerId == "posthog" {
                XCTAssertTrue(chromaticBuckets(darkPlain).isEmpty, "PostHog uses its official white variant inline on dark surfaces")
                XCTAssertGreaterThan(whitePixelCount(darkPlain), 120)
            } else {
                XCTAssertGreaterThan(chromaticBuckets(darkPlain).count, 1, "dark \(providerId) must retain its original palette")
                XCTAssertGreaterThan(centerColorPixelCount(darkPlain), 40)
            }

            let lightTile = try raster(KeyAvatar(label: providerId, kind: .provider(providerId), size: 56), background: .gray)
            let darkTile = try raster(KeyAvatar(label: providerId, kind: .provider(providerId), size: 56),
                                      scheme: .dark, appearance: .darkAqua, background: .gray)
            XCTAssertGreaterThan(centerColorPixelCount(lightTile), 40, "white tile alone cannot satisfy this \(providerId) assertion")
            XCTAssertGreaterThan(centerColorPixelCount(darkTile), 40, "dark-mode white tiles still need the coloured \(providerId) artwork")
            XCTAssertEqual(signature(lightTile, centerOnly: true), signature(darkTile, centerOnly: true),
                           "both tile appearances must use the same on-light official artwork")
        }
    }

    func test三个Apple服务符号真实存在且像素互异() throws {
        var rendered: [[UInt8]] = []
        for providerId in ["apple-notary", "apns", "developer-id"] {
            let bitmap = try raster(
                ProviderMark(providerId: providerId, size: 40, colored: true, onLightSurface: true),
                background: .white)
            XCTAssertGreaterThan(nonBackgroundPixelCount(bitmap, background: .white), 100, providerId)
            rendered.append(signature(bitmap))
        }
        XCTAssertNotEqual(rendered[0], rendered[1])
        XCTAssertNotEqual(rendered[0], rendered[2])
        XCTAssertNotEqual(rendered[1], rendered[2])
    }

    func testOpenAI官方图标在小尺寸下不会被资源内留白缩成小点() throws {
        let image = try XCTUnwrap(ProviderMarks.image(for: "openai", size: 64))
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var minX = bitmap.pixelsWide
        var maxX = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }

        XCTAssertGreaterThanOrEqual(
            CGFloat(maxX - minX + 1) / CGFloat(bitmap.pixelsWide),
            0.80,
            "OpenAI mark should carry the visual weight of the other provider icons")
    }

    func test深色模式白色服务商卡片仍完整显示深色官方图() throws {
        _ = NSApplication.shared
        let root = KeyAvatar(label: "OpenAI", kind: .provider("openai"), size: 64)
            .environment(\.colorScheme, .dark)
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
        view.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var minX = bitmap.pixelsWide
        var maxX = -1
        for y in 8..<(bitmap.pixelsHigh - 8) {
            for x in 8..<(bitmap.pixelsWide - 8) {
                guard let color = bitmap.colorAt(x: x, y: y),
                      color.alphaComponent > 0.5,
                      color.brightnessComponent < 0.35 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }

        XCTAssertGreaterThanOrEqual(maxX - minX + 1, 24, "the white tile must not wash out most of the mark")
    }

    func test每个服务商都有主题色_官方标能渲染_其余明确退回字母标() {
        let catalogIds = Set(ProviderCatalog.all.map(\.id))
        XCTAssertEqual(Set(ProviderMarks.brandHexes.keys), catalogIds)
        XCTAssertEqual(Set(ProviderMarks.sourceURLs.keys), catalogIds)

        for template in ProviderCatalog.all {
            XCTAssertNotNil(ProviderMarks.brandColor(for: template.id), template.id)
            XCTAssertTrue(ProviderMarks.sourceURLs[template.id]?.hasPrefix("https://") == true, template.id)
            if let image = ProviderMarks.image(for: template.id) {
                XCTAssertEqual(image.isTemplate, ProviderMarks.marks[template.id]?.isTemplate, template.id)
                XCTAssertGreaterThan(image.size.width, 0, template.id)
                XCTAssertTrue(ProviderMarks.marks[template.id]?.source.hasPrefix("https://") == true, template.id)
            } else {
                XCTAssertFalse(ProviderMarks.letter(for: template.id).isEmpty, template.id)
            }
        }

        let lettermarkIds = catalogIds.subtracting(ProviderMarks.marks.keys)
        XCTAssertEqual(lettermarkIds, [
            "groq", "twilio", "sendgrid", "sendgrid-eu", "mailgun",
        ])

        XCTAssertNotNil(ProviderMarks.image(for: "openai"))
        XCTAssertNotNil(ProviderMarks.image(for: "feishu"))
        XCTAssertNotNil(ProviderMarks.image(for: "zhipu"))
        XCTAssertNotNil(ProviderMarks.image(for: "kimi"))
        XCTAssertNotNil(ProviderMarks.image(for: "deepseek"))
        XCTAssertNotNil(ProviderMarks.image(for: "stripe"))
        XCTAssertNotNil(ProviderMarks.image(for: "github"))
        XCTAssertNotNil(ProviderMarks.image(for: "gemini"))
        XCTAssertNotNil(ProviderMarks.image(for: "anthropic"))
        XCTAssertNotNil(ProviderMarks.image(for: "siliconflow"))
        XCTAssertNotNil(ProviderMarks.image(for: "slack"))
        XCTAssertNotNil(ProviderMarks.image(for: "slack-oauth-rotating"))
        XCTAssertNotNil(ProviderMarks.image(for: "lark"))
        XCTAssertNotNil(ProviderMarks.image(for: "siliconflow-global"))
        XCTAssertNotNil(ProviderMarks.image(for: "minimax-token-plan-global"))
        for id in [
            "volcengine-ark", "volcengine-ark-coding", "aws", "aws-sts", "azure",
            "app-store-connect", "app-store-connect-individual", "telegram", "posthog", "posthog-eu",
            "apple-notary", "apple-notary-api-key", "apns", "developer-id", "developer-id-installer",
        ] {
            XCTAssertNotNil(ProviderMarks.image(for: id), "\(id) should use provider-owned artwork or an Apple system symbol")
        }
        XCTAssertTrue(ProviderMarks.image(for: "openai")?.isTemplate == true)
        XCTAssertTrue(ProviderMarks.image(for: "feishu")?.isTemplate == false)
        XCTAssertTrue(ProviderMarks.image(for: "zhipu")?.isTemplate == false)
        XCTAssertTrue(ProviderMarks.image(for: "kimi")?.isTemplate == false)
        for id in ["volcengine-ark", "aws", "azure", "app-store-connect", "telegram", "posthog"] {
            XCTAssertTrue(ProviderMarks.image(for: id)?.isTemplate == false, "official \(id) artwork must keep its original colours")
        }
        for id in ["apple-notary", "apns", "developer-id"] {
            XCTAssertTrue(ProviderMarks.image(for: id)?.isTemplate == true, "Apple service symbols should adapt to the surrounding UI")
        }
        XCTAssertEqual(ProviderMarks.marks["openai"]?.source, "https://cdn.openai.com/brand/openai-logos.zip")
        XCTAssertEqual(ProviderMarks.marks["feishu"]?.source, "https://p1-hera.feishucdn.com/tos-cn-i-jbbdkfciu3/84a9f036fe2b44f99b899fff4beeb963~tplv-jbbdkfciu3-image:100:100.image")
        XCTAssertEqual(ProviderMarks.marks["zhipu"]?.source, "https://z-cdn.chatglm.cn/z-ai/static/logo.svg")
        XCTAssertEqual(ProviderMarks.marks["kimi"]?.source, "https://moonshotai.github.io/Branding-Guide/scenarios/04-k-only/k-only-light.svg")
        XCTAssertEqual(ProviderMarks.marks["slack"]?.source, "https://a.slack-edge.com/80588/marketing/img/meta/slack_hash_256.png")
        XCTAssertEqual(ProviderMarks.marks["volcengine-ark"]?.source, "https://res.gcloudcache.com/volc-fe/console-ark/ark-new-main/arkIcon.svg")
        XCTAssertEqual(ProviderMarks.marks["aws"]?.source, "https://a0.awsstatic.com/libra-css/images/site/touch-icon-iphone-114-smile.png")
        XCTAssertEqual(ProviderMarks.marks["azure"]?.source, "https://learn.microsoft.com/en-us/azure/architecture/icons/")
        XCTAssertEqual(ProviderMarks.marks["app-store-connect"]?.source, "https://developer.apple.com/assets/elements/icons/app-store-connect/app-store-connect-32x32_2x.png")
        XCTAssertEqual(ProviderMarks.marks["telegram"]?.source, "https://telegram.org/img/t_logo.svg")
        XCTAssertEqual(ProviderMarks.marks["posthog"]?.source, "https://posthog.com/handbook/brand/assets")
        XCTAssertEqual(ProviderMarks.marks["apple-notary"]?.systemSymbolName, "checkmark.seal.fill")
        XCTAssertEqual(ProviderMarks.marks["apns"]?.systemSymbolName, "bell.badge.fill")
        XCTAssertEqual(ProviderMarks.marks["developer-id"]?.systemSymbolName, "person.text.rectangle.fill")
        XCTAssertNil(ProviderMarks.image(for: "mailgun"))
        XCTAssertNil(ProviderMarks.image(for: "nope"))
        XCTAssertNil(ProviderMarks.brandColor(for: "nope"))
    }

    func test命令行Agent映射到桌面App的图标_没装就字母标() {
        XCTAssertEqual(CallerAppIcon.desktopBundleIds(for: "com.anthropic.claude-code").first, "com.anthropic.claudefordesktop")
        XCTAssertEqual(CallerAppIcon.desktopBundleIds(for: "com.openai.codex"), ["com.openai.codex", "com.openai.codex"])
        XCTAssertEqual(CallerAppIcon.desktopBundleIds(for: "python3"), ["python3"])
        XCTAssertNil(CallerAppIcon.image(for: "com.example.not-installed-\(UUID().uuidString)"))
    }

    func test保存弹窗的服务商行带上图标() {
        let request = ClipboardSaveRequest(credentialId: "stripe", fieldName: "stripe-api-key", create: true, provider: "stripe")
        let model = TrustPromptModel.save(.init(request: request, callerName: "com.openai.codex"))
        let provider = model.rows.first { $0.label == "Provider" }!
        XCTAssertEqual(provider.icon, .provider("stripe"))
        XCTAssertEqual(model.rows.first { $0.label == "Requested by" }?.icon, .caller("com.openai.codex"))
    }
}
