import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Display

/// On a P3 phone every DrawingContext is Display P3, so drawing an sRGB photo or avatar into it runs
/// a ColorSync conversion per pixel on the CPU (1.1 s in a 10.9 min device session).
/// `drawingColorSpace(forSourceImage:)` picks sRGB for sources that have no wide-gamut colours.
final class DrawingContextColorSpaceTests: XCTestCase {
    private static let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// A photo-like gradient with noise, encoded as JPEG in `space` and decoded lazily like PhotoResources does.
    private func makeJpeg(width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let data = context.data else {
            return nil
        }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 12345
        for y in 0 ..< height {
            for x in 0 ..< width {
                seed = seed &* 1664525 &+ 1013904223
                let noise = Int(seed >> 28)
                let offset = y * context.bytesPerRow + x * 4
                bytes[offset + 0] = UInt8(clamping: x * 255 / width + noise)
                bytes[offset + 1] = UInt8(clamping: y * 255 / height + noise)
                bytes[offset + 2] = UInt8(clamping: (x + y) * 255 / (width + height) + noise)
                bytes[offset + 3] = 255
            }
        }
        guard let image = context.makeImage() else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithData(output as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private func draw(_ image: CGImage, size: CGSize, colorSpace: CGColorSpace) -> UIImage? {
        guard let context = DrawingContext(size: size, scale: 1.0, clear: true, colorSpace: colorSpace) else {
            return nil
        }
        context.withFlippedContext { c in
            c.setBlendMode(.copy)
            c.interpolationQuality = .medium
            c.draw(image, in: CGRect(origin: CGPoint(), size: size))
        }
        return context.generateImage()
    }

    /// Largest channel difference once both images are converted to Display P3.
    private func maxDifferenceInP3(_ a: CGImage, _ b: CGImage) -> Int {
        let width = a.width
        let height = a.height
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            data.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: DrawingContextColorSpaceTests.p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return data
        }
        let pa = pixels(a)
        let pb = pixels(b)
        var result = 0
        for i in 0 ..< pa.count {
            result = max(result, abs(Int(pa[i]) - Int(pb[i])))
        }
        return result
    }

    func testColorSpaceFollowsTheSource() throws {
        let srgbJpeg = try XCTUnwrap(self.makeJpeg(width: 64, height: 48, space: DrawingContextColorSpaceTests.sRGB))
        let p3Jpeg = try XCTUnwrap(self.makeJpeg(width: 64, height: 48, space: DrawingContextColorSpaceTests.p3))
        print("[DCColor] decoded sRGB jpeg space \(srgbJpeg.colorSpace?.name.map { $0 as String } ?? "-"), P3 jpeg space \(p3Jpeg.colorSpace?.name.map { $0 as String } ?? "-")")
        XCTAssertEqual(drawingColorSpace(forSourceImage: srgbJpeg)?.name, CGColorSpace.sRGB)
        XCTAssertNil(drawingColorSpace(forSourceImage: p3Jpeg))
        XCTAssertNil(drawingColorSpace(forSourceImage: nil))
        if let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2), let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue), let image = context.makeImage() {
            XCTAssertEqual(drawingColorSpace(forSourceImage: image)?.name, CGColorSpace.sRGB)
        }
    }

    /// The image is tagged with the colour space its pixels are in.
    func testGeneratedImageCarriesTheContextColorSpace() throws {
        let context = try XCTUnwrap(DrawingContext(size: CGSize(width: 4.0, height: 4.0), scale: 1.0, clear: true, colorSpace: DrawingContextColorSpaceTests.sRGB))
        XCTAssertEqual(context.generateImage()?.cgImage?.colorSpace?.name, CGColorSpace.sRGB)
        let defaultContext = try XCTUnwrap(DrawingContext(size: CGSize(width: 4.0, height: 4.0), scale: 1.0, clear: true))
        XCTAssertEqual(defaultContext.generateImage()?.cgImage?.colorSpace?.name, DeviceGraphicsContextSettings.shared.colorSpace.name)
    }

    /// The bubble looks the same: an sRGB photo drawn into an sRGB context and shown on a P3 screen
    /// matches the same photo drawn into a P3 context. Also times both.
    func testSRGBPhotoInSRGBContextMatchesP3Context() throws {
        let jpeg = try XCTUnwrap(self.makeJpeg(width: 1280, height: 960, space: DrawingContextColorSpaceTests.sRGB))
        let size = CGSize(width: 780.0, height: 585.0)
        let p3Image = try XCTUnwrap(self.draw(jpeg, size: size, colorSpace: DrawingContextColorSpaceTests.p3)?.cgImage)
        let chosen = drawingColorSpace(forSourceImage: jpeg) ?? DrawingContextColorSpaceTests.p3
        let srgbImage = try XCTUnwrap(self.draw(jpeg, size: size, colorSpace: chosen)?.cgImage)
        let difference = self.maxDifferenceInP3(p3Image, srgbImage)
        print("[DCColor] 1280x960 sRGB jpeg -> 780x585: max channel difference in P3 \(difference)")
        XCTAssertLessThanOrEqual(difference, 2)

        func time(_ space: CGColorSpace) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 12 {
                // A fresh lazily decoded image each time, as each transform decodes its own.
                guard let image = self.makeJpegCached(jpeg) else {
                    return -1.0
                }
                let start = CACurrentMediaTime()
                _ = self.draw(image, size: size, colorSpace: space)
                best = min(best, CACurrentMediaTime() - start)
            }
            return best * 1000.0
        }
        let p3Time = time(DrawingContextColorSpaceTests.p3)
        let srgbTime = time(DrawingContextColorSpaceTests.sRGB)
        print(String(format: "[DCColor] bench 1280x960 jpeg -> 780x585 draw: P3 context %.2f ms, sRGB context %.2f ms", p3Time, srgbTime))
    }

    private var encodedJpeg: Data?

    private func makeJpegCached(_ image: CGImage) -> CGImage? {
        if self.encodedJpeg == nil {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                return nil
            }
            self.encodedJpeg = output as Data
        }
        guard let data = self.encodedJpeg, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
