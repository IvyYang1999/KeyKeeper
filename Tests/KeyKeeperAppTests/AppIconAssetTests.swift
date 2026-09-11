import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class AppIconAssetTests: XCTestCase {
    /// 【曾经的 bug】把带白色预览画布的 RGB PNG 直接打进 icns，Finder 会显示巨大的白色方框。
    func test曾经的Bug图标四角透明且主体保持可见() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconURL = repositoryRoot.appendingPathComponent("Assets/KeyKeeper.icns")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(iconURL as CFURL, nil))
        let images = (0..<CGImageSourceGetCount(source)).compactMap {
            CGImageSourceCreateImageAtIndex(source, $0, nil)
        }
        let image = try XCTUnwrap(images.max { $0.width < $1.width })
        XCTAssertEqual(image.width, image.height)
        XCTAssertGreaterThanOrEqual(image.width, 1_024)

        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        func alpha(x: Int, y: Int) -> UInt8 {
            pixels[(y * bytesPerRow) + (x * 4) + 3]
        }

        let cornerAlphas = [
            alpha(x: 0, y: 0),
            alpha(x: image.width - 1, y: 0),
            alpha(x: 0, y: image.height - 1),
            alpha(x: image.width - 1, y: image.height - 1),
        ]
        XCTAssertTrue(cornerAlphas.allSatisfy { $0 == 0 }, "图标四角必须真正透明，实际 alpha：\(cornerAlphas)")
        XCTAssertEqual(alpha(x: image.width / 2, y: image.height / 2), 255, "图标主体不能被透明化")
    }

    /// 【曾经的 bug】底板占满画布时，Finder 会把图标显示得比相邻 macOS 图标大一圈。
    func test曾经的Bug图标视觉主体保留安全边距() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconURL = repositoryRoot.appendingPathComponent("Assets/KeyKeeper.icns")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(iconURL as CFURL, nil))
        let images = (0..<CGImageSourceGetCount(source)).compactMap {
            CGImageSourceCreateImageAtIndex(source, $0, nil)
        }
        let image = try XCTUnwrap(images.max { $0.width < $1.width })

        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[(y * bytesPerRow) + (x * 4) + 3] >= 128 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        XCTAssertGreaterThanOrEqual(maxX, minX, "图标必须包含可见主体")
        XCTAssertGreaterThanOrEqual(maxY, minY, "图标必须包含可见主体")
        let widthRatio = Double(maxX - minX + 1) / Double(image.width)
        let heightRatio = Double(maxY - minY + 1) / Double(image.height)
        XCTAssertGreaterThanOrEqual(widthRatio, 0.75, "图标主体不能过小，实际宽度占比：\(widthRatio)")
        XCTAssertGreaterThanOrEqual(heightRatio, 0.75, "图标主体不能过小，实际高度占比：\(heightRatio)")
        XCTAssertLessThanOrEqual(widthRatio, 0.85, "图标主体必须保留安全边距，实际宽度占比：\(widthRatio)")
        XCTAssertLessThanOrEqual(heightRatio, 0.85, "图标主体必须保留安全边距，实际高度占比：\(heightRatio)")
    }

    /// 【曾经的 bug】macOS 26 上旧式 icns 的外形与系统模板不完全一致，Dock 会再套一层灰色底座，
    /// 图标看起来是两层（yyt 2026-09-11）。必须同时提供 Icon Composer 编译出的 Assets.car。
    func test曾经的Bug提供macOS26图标资源且Info声明CFBundleIconName() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistData = try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertNotNil(plist["CFBundleIconFile"], "旧系统仍需要 icns 后备")

        let car = repositoryRoot.appendingPathComponent("Assets/Compiled/Assets.car")
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: car.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 10_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent("Assets/AppIcon.icon/icon.json").path))

        let buildScript = try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        XCTAssertTrue(buildScript.contains("Assets/Compiled/Assets.car"), "打包脚本必须把 Assets.car 放进 App")
    }

    /// yyt 2026-09-11：先嫌“图标不透明、不是磨玻璃”，玻璃版装上后又说浅色下黄钥匙和白底
    /// “完全就是一体了，还是原来的好看”，深色和透明样式下玻璃“很有立体感”。
    /// 所以：默认浅色用实心钥匙，深色与透明（tinted）用半透明玻璃 + 高光。
    func test图标浅色用实心钥匙深色和透明用半透明玻璃() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Assets/AppIcon.icon/icon.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let group = try XCTUnwrap((json["groups"] as? [[String: Any]])?.first)
        let layer = try XCTUnwrap((group["layers"] as? [[String: Any]])?.first { $0["image-name"] as? String == "keys.png" })

        /// Value for an appearance (nil = default/light) from a `<key>-specializations` array.
        func value(_ key: String, in object: [String: Any], appearance: String?) -> Any? {
            guard let list = object["\(key)-specializations"] as? [[String: Any]] else { return object[key] }
            let match = list.first { ($0["appearance"] as? String) == appearance }
                ?? list.first { $0["appearance"] == nil }
            return match?["value"]
        }

        XCTAssertEqual(value("glass", in: layer, appearance: nil) as? Bool, false, "浅色钥匙要实心，和白底拉开对比")
        XCTAssertEqual((value("translucency", in: group, appearance: nil) as? [String: Any])?["enabled"] as? Bool, false)
        for appearance in ["dark", "tinted"] {
            XCTAssertEqual(value("glass", in: layer, appearance: appearance) as? Bool, true, "\(appearance) 下钥匙要玻璃材质")
            XCTAssertEqual((value("translucency", in: group, appearance: appearance) as? [String: Any])?["enabled"] as? Bool, true,
                           "\(appearance) 下钥匙要半透明")
            XCTAssertEqual(value("specular", in: group, appearance: appearance) as? Bool, true, "\(appearance) 下玻璃要有高光")
        }
    }
}
