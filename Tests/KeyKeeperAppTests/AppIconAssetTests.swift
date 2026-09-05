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
}
