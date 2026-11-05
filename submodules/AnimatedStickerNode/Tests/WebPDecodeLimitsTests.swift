import Foundation
import UIKit
import XCTest
import WebPBinding

/// Static stickers are decoded from received WebP data. A header can declare a canvas of 16383 x 16383 (a gigabyte of
/// pixels from a few dozen bytes), and a failed decode used to leak the bitmap and leave a UIGraphics context pushed.
final class WebPDecodeLimitsTests: XCTestCase {
    /// A WebP file made of a lossless header only: the canvas size is declared, the bitstream is missing.
    private func headerOnlyLosslessWebP(width: Int, height: Int) -> Data {
        var payload = Data([0x2f])
        let bits = UInt32(width - 1) | (UInt32(height - 1) << 14)
        var little = bits.littleEndian
        withUnsafeBytes(of: &little) { payload.append(contentsOf: $0) }
        var data = Data("RIFF".utf8)
        var riffSize = UInt32(4 + 8 + payload.count).littleEndian
        withUnsafeBytes(of: &riffSize) { data.append(contentsOf: $0) }
        data.append(Data("WEBPVP8L".utf8))
        var chunkSize = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &chunkSize) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private func makeImage(side: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    func testAHugeDeclaredCanvasIsRejectedWithoutDecoding() {
        XCTAssertNil(WebP.convert(fromWebP: self.headerOnlyLosslessWebP(width: 16383, height: 16383)))
        XCTAssertNil(WebP.convert(fromWebP: self.headerOnlyLosslessWebP(width: 4097, height: 16)))
        XCTAssertNil(WebP.convert(fromWebP: self.headerOnlyLosslessWebP(width: 16, height: 4097), fittingPixelSize: CGSize(width: 512, height: 512)))
    }

    func testCorruptDataFailsCleanlyEveryTime() {
        let truncated = self.headerOnlyLosslessWebP(width: 512, height: 512)
        for _ in 0 ..< 200 {
            XCTAssertNil(WebP.convert(fromWebP: truncated))
        }
        XCTAssertNil(WebP.convert(fromWebP: Data()))
        XCTAssertNil(WebP.convert(fromWebP: Data(repeating: 0x42, count: 64)))
        // A failed decode must not leave a graphics context pushed on the thread.
        XCTAssertNil(UIGraphicsGetCurrentContext())
    }

    func testAValidImageDecodesAtItsSizeAndFitsATarget() throws {
        let encoded = try WebP.convert(toWebP: self.makeImage(side: 64), quality: 80)

        let full = try XCTUnwrap(WebP.convert(fromWebP: encoded))
        XCTAssertEqual(full.size.width * full.scale, 64)
        XCTAssertEqual(full.size.height * full.scale, 64)

        let fitted = try XCTUnwrap(WebP.convert(fromWebP: encoded, fittingPixelSize: CGSize(width: 16, height: 16)))
        XCTAssertEqual(fitted.size.width * fitted.scale, 16)
        XCTAssertEqual(fitted.size.height * fitted.scale, 16)

        // Never enlarged.
        let notEnlarged = try XCTUnwrap(WebP.convert(fromWebP: encoded, fittingPixelSize: CGSize(width: 512, height: 512)))
        XCTAssertEqual(notEnlarged.size.width * notEnlarged.scale, 64)
    }
}
