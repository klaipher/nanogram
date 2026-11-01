import XCTest
import UIKit
import WebPKit
@testable import tgwatch_Watch_App

/// Chat bubbles decoded their image file inside `body`, so every re-evaluation of the
/// message list (each download progress update) read and decoded every visible sticker
/// and photo again, and WebP stickers were kept at their full 512 px.
final class MediaImageCacheTests: XCTestCase {
    private var webpPath: String!
    private var pngPath: String!

    override func setUpWithError() throws {
        MediaImageCache.removeAll()
        webpPath = try XCTUnwrap(Bundle.main.path(forResource: "sticker_raster", ofType: "webp", inDirectory: "SampleStickers"))
        // A 400x300 PNG for the ImageIO path.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let png = try XCTUnwrap(UIImage(cgImage: try XCTUnwrap(context.makeImage())).pngData())
        pngPath = NSTemporaryDirectory() + "media-cache-test-\(UUID().uuidString).png"
        try png.write(to: URL(fileURLWithPath: pngPath))
    }

    override func tearDown() {
        MediaImageCache.removeAll()
        if let pngPath { try? FileManager.default.removeItem(atPath: pngPath) }
    }

    func testWebPIsScaledDownToTheBubbleSize() throws {
        let image = try XCTUnwrap(MediaImageCache.image(path: webpPath, format: .webp, maxPixelSize: 240))
        let cg = try XCTUnwrap(image.cgImage)
        // The sample is 512x401.
        XCTAssertEqual(cg.width, 240)
        XCTAssertEqual(cg.height, 188)
        XCTAssertLessThan(cg.bytesPerRow * cg.height, 512 * 401 * 4 / 4)
    }

    func testScaledWebPKeepsItsPixels() throws {
        let image = try XCTUnwrap(MediaImageCache.image(path: webpPath, format: .webp, maxPixelSize: 240))
        let data = try XCTUnwrap(image.cgImage?.dataProvider?.data as Data?)
        let alphaSum = stride(from: 3, to: data.count, by: 4).reduce(0) { $0 + Int(data[$1]) }
        XCTAssertGreaterThan(alphaSum, 0, "scaled sticker is empty")
    }

    func testNeverScalesUp() throws {
        let image = try XCTUnwrap(MediaImageCache.image(path: webpPath, format: .webp, maxPixelSize: 4096))
        XCTAssertEqual(image.cgImage?.width, 512)
        XCTAssertEqual(image.cgImage?.height, 401)
    }

    func testRepeatedRequestsDecodeOnce() throws {
        let first = try XCTUnwrap(MediaImageCache.image(path: webpPath, format: .webp, maxPixelSize: 240))
        let second = try XCTUnwrap(MediaImageCache.image(path: webpPath, format: .webp, maxPixelSize: 240))
        XCTAssertTrue(first === second)
        let other = try XCTUnwrap(MediaImageCache.image(path: webpPath, format: .webp, maxPixelSize: 64))
        XCTAssertFalse(first === other)
        XCTAssertEqual(other.cgImage?.width, 64)
    }

    func testNativeImagesDecodeAndScale() throws {
        let full = try XCTUnwrap(MediaImageCache.image(path: pngPath, format: .native))
        XCTAssertEqual(full.size, CGSize(width: 400, height: 300))
        XCTAssertTrue(full === MediaImageCache.image(path: pngPath, format: .native))
        let small = try XCTUnwrap(MediaImageCache.image(path: pngPath, format: .native, maxPixelSize: 100))
        XCTAssertEqual(small.cgImage?.width, 100)
        XCTAssertEqual(small.cgImage?.height, 75)
    }

    func testMissingFileIsNil() {
        XCTAssertNil(MediaImageCache.image(path: "/nonexistent.webp", format: .webp, maxPixelSize: 240))
        XCTAssertNil(MediaImageCache.image(path: "/nonexistent.jpg", format: .native))
    }

    func testStickerThumbnailDecodesWebPThumbnails() throws {
        // Lottie bubbles showed thumbnails through UIImage(contentsOfFile:), which has no
        // WebP codec on watchOS, so a WebP thumbnail fell back to gray.
        let visual = StickerVisual(
            fileId: 1, format: .tgs, width: 512, height: 512, emoji: "",
            localPath: nil, thumbnailFileId: 2, thumbnailLocalPath: webpPath, thumbnailFormat: .webp
        )
        XCTAssertNil(UIImage(contentsOfFile: webpPath))
        XCTAssertNotNil(stickerThumbnail(visual))
    }

    /// Prints the per-body cost of a WebP sticker bubble before (decode the file every time)
    /// and after (cache hit).
    func testBenchmarkStickerBodyDecode() throws {
        let iterations = 50
        var start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            _ = WebPDecoder.decode(url: URL(fileURLWithPath: webpPath))
        }
        let uncached = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(iterations)
        _ = MediaImageCache.image(path: webpPath, format: .webp, maxPixelSize: 240)
        start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            _ = MediaImageCache.image(path: webpPath, format: .webp, maxPixelSize: 240)
        }
        let cached = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(iterations)
        print(String(format: "BENCH webp sticker body: decode %.3f ms, cached %.4f ms", uncached, cached))
        XCTAssertLessThan(cached, uncached)
    }
}
