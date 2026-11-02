import XCTest
import UIKit
import CryptoKit
import MozjpegBinding

/// Pins what the binding's JPEG library produces, so the library under it can be replaced without changing a pixel
/// or a byte. The goldens were recorded from mozjpeg 4.1.5 (the library before libjpeg-turbo 3.2.1) by the same code
/// paths on the Mac, and are reproduced by the simulator build:
/// - the upload encoder (`compressJPEGData`: quality 72, optimized Huffman, progressive),
/// - the stripped mini-thumbnail encoder (`compressMiniThumbnail`: quality 20, baseline; its fixed header is shared
///   with every other Telegram client, so its bytes are protocol),
/// - the decoder (`decompressImage`: fast IDCT and upsampling, as DirectMediaImageCache uses it).
final class JpegCodecIdentityTests: XCTestCase {
    /// A deterministic 8-bit RGB test image: gradients plus pseudo-random noise (the generator in the evaluation
    /// tool is the same).
    private func synth(width: Int, height: Int) -> [UInt8] {
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        var s: UInt32 = 0x12345678
        for y in 0 ..< height {
            for x in 0 ..< width {
                s = s &* 1664525 &+ 1013904223
                let i = (y * width + x) * 3
                rgb[i] = UInt8((UInt32(x * 255 / (width - 1)) + ((s >> 24) & 31)) & 255)
                rgb[i + 1] = UInt8((UInt32(y * 255 / (height - 1)) + ((s >> 16) & 31)) & 255)
                rgb[i + 2] = UInt8((UInt32((x + y) * 4) + ((s >> 8) & 15)) & 255)
            }
        }
        return rgb
    }

    private func image(width: Int, height: Int) -> UIImage {
        let rgb = self.synth(width: width, height: height)
        var bgrx = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0 ..< width * height {
            bgrx[i * 4] = rgb[i * 3 + 2]
            bgrx[i * 4 + 1] = rgb[i * 3 + 1]
            bgrx[i * 4 + 2] = rgb[i * 3]
        }
        let cgImage = bgrx.withUnsafeMutableBytes { buffer -> CGImage in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            return context.makeImage()!
        }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    private func sha256(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The decoded pixels, row by row without the row padding: "<w>x<h> <sha256>".
    private func decodedDigest(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), let cgImage = decompressImage(data)?.cgImage, let pixels = cgImage.dataProvider?.data as Data? else {
            return nil
        }
        var rows = Data()
        for y in 0 ..< cgImage.height {
            rows.append(pixels.subdata(in: y * cgImage.bytesPerRow ..< y * cgImage.bytesPerRow + cgImage.width * 4))
        }
        return "\(cgImage.width)x\(cgImage.height) \(self.sha256(rows))"
    }

    func testUploadEncoderBytes() {
        let path = NSTemporaryDirectory() + "JpegCodecIdentityTests-\(UUID().uuidString).jpg"
        guard let data = compressJPEGData(self.image(width: 96, height: 64), path) else {
            XCTFail("no output")
            return
        }
        XCTAssertEqual(data.count, 2108)
        XCTAssertEqual(self.sha256(data), "1eba6f9a5fa55bade4e3a451572069fba925cbd59aa3ac48f51a05f871f2a5c9")
    }

    func testMiniThumbnailBytes() {
        guard let data = compressMiniThumbnail(self.image(width: 40, height: 30), CGSize(width: 40.0, height: 40.0)) else {
            XCTFail("no output: the fixed stripped-thumbnail header no longer matches")
            return
        }
        XCTAssertEqual(data.count, 150)
        XCTAssertEqual(self.sha256(data), "fe525360a721e733eb3e7c560034bf106258561cf40d18b3f2869c2a4e06731b")
    }

    /// A stored square as DirectMediaImageCache writes it (ImageIO, quality 0.7, baseline 4:2:0).
    func testDecodeImageIOBaseline() {
        XCTAssertEqual(self.decodedDigest("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"), "96x64 3215f77d0d4474e2c7045c267122813ac82b67bf6ef9eb8ca7f3f0f1d893eca8")
    }

    /// Progressive, as the upload encoder writes it.
    func testDecodeProgressive() {
        XCTAssertEqual(self.decodedDigest("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"), "96x64 3bc093fe6cc5c5936c0455e396e7473dd40cf298d099788d3334145c305c7900")
    }

    /// A tiny thumbnail as the stripped-thumbnail header expands it.
    func testDecodeTinyThumbnail() {
        XCTAssertEqual(self.decodedDigest("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAeACgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDOEdPVKmVKkVKSYozIglPCVMEp4T2q0zohMqzxnaGHbtRVmaP5GO0dBz+NFdEHoc9efviKnsakCVVW+XI/dkc84PanfbuR8mR69M/zrlVORhCEy4Ep6pVNb1t33Rtz6dOP8/8A1qkF6dvCnPPf3/wrRU5HTCEyxInydPxoqndakPLULGNxz17UVHtJLSKMa1OTlqf/2Q=="), "40x30 91fa156232f61bd5aec3761358f186a88f4dc26f63bae922111227dd30e86bf6")
    }
}
