import XCTest
import CoreGraphics
@testable import GifVideoLayer

final class GifThumbnailCacheTests: XCTestCase {
    private func makeImage(size: Int = 4) -> CGImage? {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage()
    }

    func testNoSynchronousLoadAlwaysLoadsOffMain() {
        XCTAssertEqual(GifThumbnailCache.plan(isCached: true, synchronousLoadRequested: false, synchronousOnlyFromCache: true), .loadOffMain)
        XCTAssertEqual(GifThumbnailCache.plan(isCached: false, synchronousLoadRequested: false, synchronousOnlyFromCache: false), .loadOffMain)
    }

    func testSynchronousLoadRestrictedToCacheDecodesNothingOnMain() {
        XCTAssertEqual(GifThumbnailCache.plan(isCached: true, synchronousLoadRequested: true, synchronousOnlyFromCache: true), .applyCachedNow)
        XCTAssertEqual(GifThumbnailCache.plan(isCached: false, synchronousLoadRequested: true, synchronousOnlyFromCache: true), .loadOffMain)
    }

    func testUnrestrictedSynchronousLoadKeepsTheFormerBehaviour() {
        XCTAssertEqual(GifThumbnailCache.plan(isCached: false, synchronousLoadRequested: true, synchronousOnlyFromCache: false), .loadOnMain)
        XCTAssertEqual(GifThumbnailCache.plan(isCached: true, synchronousLoadRequested: true, synchronousOnlyFromCache: false), .loadOnMain)
    }

    func testStoreAndLookup() {
        let cache = GifThumbnailCache(totalCostLimit: 1024 * 1024)
        let key = GifThumbnailCache.key(namespace: 1, id: 42, width: 93, height: 93)
        XCTAssertNil(cache.image(forKey: key))
        guard let image = self.makeImage() else {
            XCTFail("could not create an image")
            return
        }
        cache.store(image, forKey: key)
        XCTAssertTrue(cache.image(forKey: key) === image)
        XCTAssertNil(cache.image(forKey: GifThumbnailCache.key(namespace: 2, id: 42, width: 93, height: 93)), "the namespace is part of the key")
        cache.removeAll()
        XCTAssertNil(cache.image(forKey: key))
    }
}
