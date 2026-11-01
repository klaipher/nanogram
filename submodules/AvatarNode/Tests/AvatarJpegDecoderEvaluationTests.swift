import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import MozjpegBinding

/// Evaluation only (nothing ships from it): libjpeg-turbo via MozjpegBinding.decompressImage against
/// ImageIO for avatar-sized JPEGs. Reports time and the largest channel difference after drawing both
/// into the same 8-bit sRGB context. ImageIO decodes in software in the simulator; the device
/// hardware path (whose IPC is the cost being avoided) cannot be measured here.
final class AvatarJpegDecoderEvaluationTests: XCTestCase {
    private func makeJPEG(side: Int, seed: UInt32) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            var state = seed
            for y in stride(from: 0, to: side, by: 4) {
                for x in stride(from: 0, to: side, by: 4) {
                    state = state &* 1664525 &+ 1013904223
                    let base = CGFloat(x + y) / CGFloat(2 * side)
                    UIColor(red: base, green: CGFloat(state & 0xff) / 255.0, blue: 1.0 - base, alpha: 1.0).setFill()
                    context.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
        let data = NSMutableData()
        if let cgImage = image.cgImage, let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        return data as Data
    }

    private func draw(_ image: CGImage, side: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        bytes.withUnsafeMutableBytes { buffer in
            if let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            }
        }
        return bytes
    }

    func testCompareDecodersOnSmallAvatars() {
        for side in [160, 320, 640] {
            let jpegs = (0 ..< 10).map { self.makeJPEG(side: side, seed: UInt32(clamping: side + $0)) }
            let rounds = 5

            var start = CACurrentMediaTime()
            var imageIOImages: [CGImage] = []
            for _ in 0 ..< rounds {
                imageIOImages.removeAll()
                for jpeg in jpegs {
                    if let source = CGImageSourceCreateWithData(jpeg as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                        imageIOImages.append(image)
                    }
                }
            }
            let imageIOMs = (CACurrentMediaTime() - start) * 1000.0 / Double(rounds * jpegs.count)

            start = CACurrentMediaTime()
            var turboImages: [CGImage] = []
            for _ in 0 ..< rounds {
                turboImages.removeAll()
                for jpeg in jpegs {
                    if let image = decompressImage(jpeg)?.cgImage {
                        turboImages.append(image)
                    }
                }
            }
            let turboMs = (CACurrentMediaTime() - start) * 1000.0 / Double(rounds * jpegs.count)

            XCTAssertEqual(imageIOImages.count, jpegs.count)
            XCTAssertEqual(turboImages.count, jpegs.count)
            var maxDiff = 0
            var differing = 0
            var total = 0
            for (a, b) in zip(imageIOImages, turboImages) {
                let pa = self.draw(a, side: side)
                let pb = self.draw(b, side: side)
                for i in 0 ..< pa.count where i % 4 != 3 {
                    let d = abs(Int(pa[i]) - Int(pb[i]))
                    maxDiff = max(maxDiff, d)
                    if d > 0 {
                        differing += 1
                    }
                    total += 1
                }
            }
            let colorSpace = turboImages.first?.colorSpace?.name.map { $0 as String } ?? "nil"
            print("AvatarJpegDecoderEvaluation side \(side): ImageIO \(String(format: "%.3f", imageIOMs)) ms, libjpeg-turbo \(String(format: "%.3f", turboMs)) ms, max channel diff \(maxDiff), differing \(String(format: "%.1f", Double(differing) * 100.0 / Double(max(total, 1))))%, turbo color space \(colorSpace)")
        }
    }
}
