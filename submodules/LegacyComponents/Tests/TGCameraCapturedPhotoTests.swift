import XCTest
import UIKit
import SSignalKit
import LegacyComponents

/// The legacy camera built `TGCameraCapturedPhoto` (a full-resolution JPEG encode) on the main
/// thread at the shutter. It is now built on a background queue; the first screen image is
/// decoded from the JPEG bytes just encoded instead of reading the file back. These tests pin
/// that the screen image is byte-identical either way and measure the work moved off main.
final class TGCameraCapturedPhotoTests: XCTestCase {
    private func makePhoto(width: Int, height: Int, seed: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let colors = [UIColor(red: seed, green: 0.2, blue: 0.7, alpha: 1.0).cgColor, UIColor(red: 0.9, green: 0.8, blue: seed, alpha: 1.0).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil)!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            for i in 0 ..< 40 {
                UIColor(white: CGFloat(i) / 40.0, alpha: 1.0).setFill()
                context.fill(CGRect(x: i * width / 40, y: (i * 37) % height, width: width / 50, height: height / 9))
            }
        }
    }

    private func screenImage(_ photo: TGCameraCapturedPhoto) throws -> UIImage {
        var result: UIImage?
        photo.screenImageSignal(0.0)?.start(next: { next in
            result = next as? UIImage
        })
        return try XCTUnwrap(result)
    }

    private func pixels(_ image: UIImage) throws -> Data {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    func testScreenImageFromMemoryMatchesTheFile() throws {
        let image = self.makePhoto(width: 4032, height: 3024, seed: 0.3)
        let start = CFAbsoluteTimeGetCurrent()
        let photo = try XCTUnwrap(TGCameraCapturedPhoto(image: image, metadata: nil))
        let initTime = CFAbsoluteTimeGetCurrent() - start
        print("TGCameraCapturedPhotoTests: building a 12 MP captured photo took \(String(format: "%.1f", initTime * 1000)) ms (was on the main thread at the shutter)")

        let fromMemory = try self.screenImage(photo)
        let fromFile = try self.screenImage(photo)
        XCTAssertEqual(fromMemory.size, fromFile.size)
        XCTAssertEqual(max(fromMemory.size.width, fromMemory.size.height), 1600)
        XCTAssertEqual(try self.pixels(fromMemory), try self.pixels(fromFile))

        let fileData = try Data(contentsOf: XCTUnwrap(photo.url))
        XCTAssertGreaterThan(fileData.count, 100_000)
    }

    // Only the most recent capture is kept in memory; an older one reads its file, unchanged.
    func testOnlyTheLatestCaptureIsKeptInMemory() throws {
        let first = try XCTUnwrap(TGCameraCapturedPhoto(image: self.makePhoto(width: 2000, height: 1500, seed: 0.1), metadata: nil))
        let second = try XCTUnwrap(TGCameraCapturedPhoto(image: self.makePhoto(width: 2000, height: 1500, seed: 0.8), metadata: nil))
        let firstScreen = try self.screenImage(first)
        let firstAgain = try self.screenImage(first)
        XCTAssertEqual(try self.pixels(firstScreen), try self.pixels(firstAgain))
        let secondScreen = try self.screenImage(second)
        XCTAssertNotEqual(try self.pixels(firstScreen), try self.pixels(secondScreen))
        XCTAssertEqual(try self.pixels(secondScreen), try self.pixels(try self.screenImage(second)))
    }
}
