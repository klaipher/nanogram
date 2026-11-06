import Foundation
import XCTest
import CoreGraphics
import ImageIO
import ImageDecodeSizing

final class ImageDecodeSizingTests: XCTestCase {
    private func makeJPEG(width: Int, height: Int) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    func testLargeSourceForSmallTargetGetsAThumbnailSizeThatCoversBothDimensions() {
        let value = ImageDecodeSizing.thumbnailMaxPixelSize(sourceWidth: 4000, sourceHeight: 3000, targetPixelSize: CGSize(width: 600, height: 450))
        XCTAssertEqual(value, 600)
    }

    func testTargetWiderThanTheSourceAspectStillCoversTheShortSide() {
        let value = ImageDecodeSizing.thumbnailMaxPixelSize(sourceWidth: 4000, sourceHeight: 1000, targetPixelSize: CGSize(width: 600, height: 300))
        XCTAssertEqual(value, 1200)
    }

    func testNearlyTargetSizedSourceIsLeftAlone() {
        XCTAssertNil(ImageDecodeSizing.thumbnailMaxPixelSize(sourceWidth: 1000, sourceHeight: 750, targetPixelSize: CGSize(width: 800, height: 600)))
        XCTAssertNil(ImageDecodeSizing.thumbnailMaxPixelSize(sourceWidth: 1200, sourceHeight: 900, targetPixelSize: CGSize(width: 800, height: 600)))
    }

    func testSmallSourceAndDegenerateInputsAreLeftAlone() {
        XCTAssertNil(ImageDecodeSizing.thumbnailMaxPixelSize(sourceWidth: 100, sourceHeight: 100, targetPixelSize: CGSize(width: 800, height: 600)))
        XCTAssertNil(ImageDecodeSizing.thumbnailMaxPixelSize(sourceWidth: 0, sourceHeight: 100, targetPixelSize: CGSize(width: 8, height: 6)))
        XCTAssertNil(ImageDecodeSizing.thumbnailMaxPixelSize(sourceWidth: 100, sourceHeight: 100, targetPixelSize: .zero))
        XCTAssertNil(ImageDecodeSizing.thumbnailMaxPixelSize(sourceWidth: 100, sourceHeight: 100, targetPixelSize: CGSize(width: CGFloat.infinity, height: 5)))
    }

    func testRealJPEGIsDecodedAtLeastAsLargeAsTheTargetAndNoLargerThanTheSource() throws {
        let data = try XCTUnwrap(makeJPEG(width: 2400, height: 1800))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(ImageDecodeSizing.downscaledImage(source: source, targetPixelSize: CGSize(width: 600, height: 450)))
        XCTAssertGreaterThanOrEqual(image.width, 600)
        XCTAssertGreaterThanOrEqual(image.height, 450)
        XCTAssertLessThan(image.width, 2400)
    }

    func testRealJPEGCloseToTheTargetIsNotRedecoded() throws {
        let data = try XCTUnwrap(makeJPEG(width: 800, height: 600))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertNil(ImageDecodeSizing.downscaledImage(source: source, targetPixelSize: CGSize(width: 600, height: 450)))
    }
}
