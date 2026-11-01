import XCTest
import CryptoKit
@testable import WebPKit

/// WebP decoding is specified bit-exactly, so a libwebp update must decode a real Telegram
/// sticker to the same pixels. The digest was recorded with libwebp 1.4.0.
final class WebPDecodeParityTests: XCTestCase {
    private static let expectedDigest = "47703548efa21f90da8de9c998fc47df52b4e6ea13bdf6a7b20ce9ca67f67b38"

    func testStickerPixelsMatchReference() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sticker_raster", withExtension: "webp"))
        let image = try XCTUnwrap(WebPDecoder.decode(data: try Data(contentsOf: url)))
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        let digest = SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
        if ProcessInfo.processInfo.environment["WEBP_RECORD"] != nil {
            print("WEBP_DIGEST \(digest)")
            return
        }
        XCTAssertEqual(digest, Self.expectedDigest)
    }
}
