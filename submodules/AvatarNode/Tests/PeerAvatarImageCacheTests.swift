import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import AvatarNode

/// `peerAvatarImage` decoded and clipped the avatar JPEG on every call (1.6 s CPU in a 10.9 min
/// device session, mostly hardware-JPEG IPC). Rendered results are now kept in a bounded cache.
final class PeerAvatarImageCacheTests: XCTestCase {
    private func makeJPEG(side: Int, seed: UInt32) -> Data {
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            return format
        }()).image { context in
            var state = seed
            for y in stride(from: 0, to: side, by: 8) {
                for x in stride(from: 0, to: side, by: 8) {
                    state = state &* 1664525 &+ 1013904223
                    let r = CGFloat(state & 0xff) / 255.0
                    let g = CGFloat((state >> 8) & 0xff) / 255.0
                    let b = CGFloat((state >> 16) & 0xff) / 255.0
                    UIColor(red: r, green: g, blue: b, alpha: 1.0).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        let data = NSMutableData()
        guard let cgImage = image.cgImage, let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            XCTFail("could not encode")
            return Data()
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func pixels(_ image: UIImage) -> [UInt8] {
        guard let cgImage = image.cgImage else {
            return []
        }
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            if let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return bytes
    }

    private func render(_ data: (Data, PeerAvatarImageType)?, resourceId: String? = "avatar-1", size: CGSize = CGSize(width: 60.0, height: 60.0), clipStyle: AvatarNodeClipStyle = .round, blurred: Bool = false, provideUnrounded: Bool = false, cache: PeerAvatarImageCache?) -> (UIImage, UIImage)? {
        return peerAvatarRenderedImages(resourceId: resourceId, data: data, displayDimensions: size, clipStyle: clipStyle, blurred: blurred, inset: 0.0, emptyColor: nil, provideUnrounded: provideUnrounded, cutoutRect: nil, cache: cache)
    }

    func testSecondRenderIsServedFromCacheWithIdenticalPixels() {
        let cache = PeerAvatarImageCache(totalCostLimit: 4 * 1024 * 1024)
        let data = (self.makeJPEG(side: 160, seed: 1), PeerAvatarImageType.complete)

        guard let first = self.render(data, cache: cache), let second = self.render(data, cache: cache), let uncached = self.render(data, cache: nil) else {
            XCTFail("render failed")
            return
        }
        XCTAssertTrue(first.0 === second.0, "second call must reuse the rendered image")
        XCTAssertFalse(first.0 === uncached.0)
        XCTAssertEqual(self.pixels(first.0), self.pixels(uncached.0))
        XCTAssertEqual(first.0.size, uncached.0.size)
        XCTAssertEqual(first.0.scale, uncached.0.scale)
    }

    func testEveryRenderInputIsPartOfTheKey() {
        let cache = PeerAvatarImageCache(totalCostLimit: 4 * 1024 * 1024)
        let data = (self.makeJPEG(side: 160, seed: 2), PeerAvatarImageType.complete)
        guard let base = self.render(data, cache: cache) else {
            XCTFail("render failed")
            return
        }
        let variants: [(UIImage, UIImage)?] = [
            self.render(data, resourceId: "avatar-2", cache: cache),
            self.render(data, size: CGSize(width: 40.0, height: 40.0), cache: cache),
            self.render(data, clipStyle: .roundedRect, cache: cache),
            self.render(data, blurred: true, cache: cache),
            self.render(data, provideUnrounded: true, cache: cache),
            self.render((self.makeJPEG(side: 161, seed: 2), .complete), cache: cache)
        ]
        for (index, variant) in variants.enumerated() {
            XCTAssertNotNil(variant, "\(index)")
            XCTAssertFalse(variant?.0 === base.0, "variant \(index) must not hit the base entry")
        }
    }

    func testThumbnailsAndUnknownResourcesAreNotCached() {
        let cache = PeerAvatarImageCache(totalCostLimit: 4 * 1024 * 1024)
        let jpeg = self.makeJPEG(side: 64, seed: 3)
        let blurredA = self.render((jpeg, .blurred), cache: cache)
        let blurredB = self.render((jpeg, .blurred), cache: cache)
        XCTAssertFalse(blurredA?.0 === blurredB?.0)

        let anonymousA = self.render((jpeg, .complete), resourceId: nil, cache: cache)
        let anonymousB = self.render((jpeg, .complete), resourceId: nil, cache: cache)
        XCTAssertFalse(anonymousA?.0 === anonymousB?.0)

        // A failed decode still yields a blank image (unchanged behaviour); it must not be kept.
        let undecodableA = self.render((Data([1, 2, 3]), .complete), cache: cache)
        let undecodableB = self.render((Data([1, 2, 3]), .complete), cache: cache)
        XCTAssertFalse(undecodableA?.0 === undecodableB?.0)
    }

    func testMemoryWarningAndBackgroundPurge() {
        let cache = PeerAvatarImageCache(totalCostLimit: 4 * 1024 * 1024)
        let data = (self.makeJPEG(side: 160, seed: 4), PeerAvatarImageType.complete)
        let first = self.render(data, cache: cache)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let second = self.render(data, cache: cache)
        XCTAssertFalse(first?.0 === second?.0)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let third = self.render(data, cache: cache)
        XCTAssertFalse(second?.0 === third?.0)
    }

    func testLargeRendersAreNotKept() {
        let cache = PeerAvatarImageCache(totalCostLimit: 4 * 1024 * 1024)
        let data = (self.makeJPEG(side: 640, seed: 5), PeerAvatarImageType.complete)
        // Over 1 MB at any scale: 600 x 600 x 4 bytes at 1x.
        let size = CGSize(width: 600.0, height: 600.0)
        let first = self.render(data, size: size, cache: cache)
        let second = self.render(data, size: size, cache: cache)
        XCTAssertNotNil(first)
        if let cgImage = first?.0.cgImage {
            XCTAssertGreaterThan(cgImage.bytesPerRow * cgImage.height, PeerAvatarImageCache.maximumEntryCost)
        }
        XCTAssertFalse(first?.0 === second?.0)
    }

    /// Simulator numbers: ImageIO decodes in software here, while on device small avatars go
    /// through the hardware JPEG path (about 4 ms of CPU per avatar, mostly IPC).
    func testBenchmarkRenderVersusHit() {
        let cache = PeerAvatarImageCache(totalCostLimit: 8 * 1024 * 1024)
        let datas = (0 ..< 20).map { (self.makeJPEG(side: 160, seed: UInt32(clamping: 100 + $0)), PeerAvatarImageType.complete) }
        let rounds = 10

        var start = CACurrentMediaTime()
        for _ in 0 ..< rounds {
            for (index, data) in datas.enumerated() {
                _ = self.render(data, resourceId: "bench-\(index)", cache: nil)
            }
        }
        let uncachedMs = (CACurrentMediaTime() - start) * 1000.0 / Double(rounds * datas.count)

        for (index, data) in datas.enumerated() {
            _ = self.render(data, resourceId: "bench-\(index)", cache: cache)
        }
        start = CACurrentMediaTime()
        for _ in 0 ..< rounds {
            for (index, data) in datas.enumerated() {
                _ = self.render(data, resourceId: "bench-\(index)", cache: cache)
            }
        }
        let cachedMs = (CACurrentMediaTime() - start) * 1000.0 / Double(rounds * datas.count)
        print("PeerAvatarImageCache benchmark: render \(String(format: "%.3f", uncachedMs)) ms, hit \(String(format: "%.4f", cachedMs)) ms per 60 pt avatar")
        XCTAssertLessThan(cachedMs, uncachedMs)
    }
}
