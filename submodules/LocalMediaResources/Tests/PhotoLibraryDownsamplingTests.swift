import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import LocalMediaResources

/// Sending a gallery photo decoded the whole 24/48 MP photo and scaled it on the CPU. It now
/// decodes at the upload size with ImageIO from the photo's data. These tests compare the new
/// path with the full-decode path on camera-like photos (24 MP, Display P3, EXIF orientation 6,
/// grain): identical output size, near-identical pixels (SSIM), and peak memory.
final class PhotoLibraryDownsamplingTests: XCTestCase {
    private static func makePhotoData(width: Int, height: Int, type: UTType, orientation: UInt32, seed: UInt32) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1.0), CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1.0)] as CFArray
        context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3)!, colors: colors, locations: nil)!, start: .zero, end: CGPoint(x: width, y: height), options: [])
        for i in 0 ..< 60 {
            context.setFillColor(CGColor(red: CGFloat(i % 7) / 7.0, green: CGFloat(i % 5) / 5.0, blue: CGFloat(i % 3) / 3.0, alpha: 1.0))
            context.fillEllipse(in: CGRect(x: (i * 397) % width, y: (i * 211) % height, width: width / 12, height: height / 15))
        }
        let base = context.data!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = context.bytesPerRow
        var state = seed
        for y in 0 ..< height {
            let row = base + y * bytesPerRow
            for x in 0 ..< width {
                state = state &* 1664525 &+ 1013904223
                let grain = Int((state >> 24) & 15) - 8
                for c in 0 ..< 3 {
                    row[x * 4 + c] = UInt8(clamping: Int(row[x * 4 + c]) + grain)
                }
            }
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85, kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The full-size path: the whole photo decoded upright (as PhotoKit hands it over), then
    /// scaled by `resizedImage`.
    private func fullDecodePath(data: Data, maxSize: CGSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        guard let full = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height), kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            return nil
        }
        let image = UIImage(cgImage: full)
        return resizedImage(image, for: photoLibraryUploadSize(orientedPixelSize: image.size, maxSize: maxSize))
    }

    private func luma(_ image: UIImage) -> (width: Int, height: Int, values: [Float]) {
        let cgImage = image.cgImage!
        let width = cgImage.width
        let height = cgImage.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var values = [Float](repeating: 0, count: width * height)
        for i in 0 ..< width * height {
            values[i] = 0.299 * Float(rgba[i * 4]) + 0.587 * Float(rgba[i * 4 + 1]) + 0.114 * Float(rgba[i * 4 + 2])
        }
        return (width, height, values)
    }

    /// Mean SSIM over 8x8 windows of luma.
    private func ssim(_ a: UIImage, _ b: UIImage) -> Double {
        let la = self.luma(a)
        let lb = self.luma(b)
        precondition(la.width == lb.width && la.height == lb.height)
        let c1: Double = (0.01 * 255) * (0.01 * 255)
        let c2: Double = (0.03 * 255) * (0.03 * 255)
        var total = 0.0
        var count = 0
        var y = 0
        while y + 8 <= la.height {
            var x = 0
            while x + 8 <= la.width {
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
                for dy in 0 ..< 8 {
                    for dx in 0 ..< 8 {
                        let va = Double(la.values[(y + dy) * la.width + x + dx])
                        let vb = Double(lb.values[(y + dy) * lb.width + x + dx])
                        sa += va
                        sb += vb
                        saa += va * va
                        sbb += vb * vb
                        sab += va * vb
                    }
                }
                let n = 64.0
                let ma = sa / n, mb = sb / n
                let va = saa / n - ma * ma, vb = sbb / n - mb * mb, cov = sab / n - ma * mb
                total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                count += 1
                x += 8
            }
            y += 8
        }
        return total / Double(count)
    }

    private func peakFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(max(0, info.ledger_phys_footprint_peak)) : 0
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func testUploadSizeArithmeticIsUnchanged() {
        XCTAssertEqual(photoLibraryUploadSize(orientedPixelSize: CGSize(width: 4284, height: 5712), maxSize: CGSize(width: 1280, height: 1280)), CGSize(width: 960, height: 1280))
        XCTAssertEqual(photoLibraryUploadSize(orientedPixelSize: CGSize(width: 4032, height: 2268), maxSize: CGSize(width: 2560, height: 2560)), CGSize(width: 2560, height: 1440))
        XCTAssertEqual(photoLibraryUploadSize(orientedPixelSize: CGSize(width: 1000, height: 700), maxSize: CGSize(width: 1280, height: 1280)), CGSize(width: 1000, height: 700))
        XCTAssertEqual(photoLibraryUploadSize(orientedPixelSize: CGSize(width: 4000, height: 3001), maxSize: CGSize(width: 1280, height: 1280)), CGSize(width: 1280, height: 960))
    }

    func testDownsampledPhotoMatchesTheFullDecodePath() throws {
        let fixtures: [(String, UTType, UInt32)] = [("JPEG o6", .jpeg, 6), ("HEIC o6", .heic, 6), ("JPEG o1", .jpeg, 1), ("HEIC o8", .heic, 8)]
        var report: [String] = []
        for (name, type, orientation) in fixtures {
            let data = Self.makePhotoData(width: 5712, height: 4284, type: type, orientation: orientation, seed: orientation)
            for side in [1280.0, 2560.0] {
                let maxSize = CGSize(width: side, height: side)
                let footprintBefore = self.footprint()
                let peakBefore = self.peakFootprint()
                var startTime = CFAbsoluteTimeGetCurrent()
                let downsampled = try XCTUnwrap(autoreleasepool { downsampledPhotoLibraryImage(data: data, maxSize: maxSize, resize: resizedImage) }, name)
                let newTime = CFAbsoluteTimeGetCurrent() - startTime
                let newPeak = Int64(self.peakFootprint()) - Int64(max(peakBefore, footprintBefore))
                startTime = CFAbsoluteTimeGetCurrent()
                let reference = try XCTUnwrap(autoreleasepool { self.fullDecodePath(data: data, maxSize: maxSize) }, name)
                let referenceTime = CFAbsoluteTimeGetCurrent() - startTime
                let referencePeak = Int64(self.peakFootprint()) - Int64(footprintBefore)

                XCTAssertEqual(downsampled.size, reference.size, "\(name) \(side)")
                XCTAssertEqual(downsampled.imageOrientation, .up)
                let expected = orientation >= 5 ? CGSize(width: side * 4284 / 5712, height: side) : CGSize(width: side, height: side * 4284 / 5712)
                XCTAssertEqual(downsampled.size, CGSize(width: floor(expected.width), height: floor(expected.height)), "\(name) \(side)")
                let similarity = self.ssim(downsampled, reference)
                XCTAssertGreaterThan(similarity, 0.97, "\(name) \(side)")
                report.append("\(name) \(Int(side)): SSIM \(String(format: "%.4f", similarity)), \(String(format: "%.0f", newTime * 1000)) ms vs \(String(format: "%.0f", referenceTime * 1000)) ms, peak +\(max(0, newPeak) / 1_000_000) MB vs +\(max(0, referencePeak) / 1_000_000) MB")
            }
        }
        print("PhotoLibraryDownsamplingTests:\n" + report.joined(separator: "\n"))
    }

    func testDeepAndRawPhotosFallBackToTheFullSizePath() throws {
        // A 16-bit PNG stands in for a 10-bit HEIF: anything deeper than 8 bits keeps the old path.
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 16, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertNil(downsampledPhotoLibraryImage(data: data as Data, maxSize: CGSize(width: 1280, height: 1280), resize: resizedImage))
        XCTAssertNil(downsampledPhotoLibraryImage(data: Data("not an image".utf8), maxSize: CGSize(width: 1280, height: 1280), resize: resizedImage))
    }
}
