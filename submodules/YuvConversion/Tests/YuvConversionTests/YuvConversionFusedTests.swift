import Foundation
import XCTest
import Accelerate
import YuvConversion

// The previous implementations of YUV.m, step by step: convert to ARGB, write alpha into byte 0,
// premultiply (or unpremultiply) ARGB, permute to BGRA. The fused versions must match them exactly.
private func referenceDecodeYUVAToRGBA(_ yuva: UnsafePointer<UInt8>, _ argb: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
    var info = vImage_YpCbCrToARGB()
    var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 1, CbCrMax: 255, CbCrMin: 0)
    vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &pixelRange, &info, kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, 0)

    var srcYp = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: yuva), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
    var srcCbCr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: yuva + width * height), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
    var dest = vImage_Buffer(data: argb, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
    vImageConvert_420Yp8_CbCr8ToARGB8888(&srcYp, &srcCbCr, &dest, &info, nil, 0xff, vImage_Flags(kvImageDoNotTile))

    let alpha = yuva + width * height * 2
    var i = 0
    for y in 0 ..< height {
        let row = argb + y * bytesPerRow
        var x = 0
        while x < width {
            let a = alpha[i / 2]
            let a1 = a & 0xf0
            let a2 = (a & 0x0f) << 4
            row[x * 4] = a1 | (a1 >> 4)
            // The old loop also wrote pixel `width` of an odd row; only pixels inside the row are compared.
            row[(x + 1) * 4] = a2 | (a2 >> 4)
            i += 2
            x += 2
        }
    }
    vImagePremultiplyData_ARGB8888(&dest, &dest, vImage_Flags(kvImageDoNotTile))
    let permuteMap: [UInt8] = [3, 2, 1, 0]
    vImagePermuteChannels_ARGB8888(&dest, &dest, permuteMap, vImage_Flags(kvImageDoNotTile))
}

private func referenceDecodeYUVAPlanesToRGBA(y yPlane: UnsafePointer<UInt8>, yStride: Int, cb: UnsafePointer<UInt8>, cbStride: Int, cr: UnsafePointer<UInt8>, crStride: Int, hasAlpha: Bool, alpha: UnsafePointer<UInt8>, argb: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, unpremultiply: Bool) {
    var info = vImage_YpCbCrToARGB()
    var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
    vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &pixelRange, &info, kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, 0)

    var srcYp = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: yPlane), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: yStride)
    var srcCb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: cb), height: vImagePixelCount(height), width: vImagePixelCount(width / 2), rowBytes: cbStride)
    var srcCr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: cr), height: vImagePixelCount(height), width: vImagePixelCount(width / 2), rowBytes: crStride)
    var dest = vImage_Buffer(data: argb, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
    vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&srcYp, &srcCb, &srcCr, &dest, &info, nil, 0xff, vImage_Flags(kvImageDoNotTile))
    if hasAlpha {
        for y in 0 ..< height {
            let row = argb + y * bytesPerRow
            for x in 0 ..< width {
                row[x * 4] = alpha[y * yStride + x]
            }
        }
    }
    if unpremultiply {
        vImageUnpremultiplyData_ARGB8888(&dest, &dest, vImage_Flags(kvImageDoNotTile))
    } else {
        vImagePremultiplyData_ARGB8888(&dest, &dest, vImage_Flags(kvImageDoNotTile))
    }
    let permuteMap: [UInt8] = [3, 2, 1, 0]
    vImagePermuteChannels_ARGB8888(&dest, &dest, permuteMap, vImage_Flags(kvImageDoNotTile))
}

private struct Random {
    var state: UInt64

    mutating func next() -> UInt8 {
        self.state = self.state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: self.state >> 33)
    }

    // Mostly random, with runs of fully transparent and fully opaque values like real sticker edges.
    mutating func nextAlpha(_ index: Int) -> UInt8 {
        switch index % 11 {
        case 0, 1:
            return 0
        case 2, 3:
            return 0xff
        default:
            return self.next()
        }
    }
}

private let sentinel: UInt8 = 0x5a

final class YuvConversionFusedTests: XCTestCase {
    private let sizes: [(Int, Int)] = [(2, 2), (16, 16), (64, 64), (100, 64), (101, 37), (160, 160), (255, 3), (512, 512)]

    // Pixels inside each row must match the reference; padding after a row must stay untouched.
    private func compare(_ expected: [UInt8], _ actual: [UInt8], width: Int, height: Int, bytesPerRow: Int, file: StaticString = #filePath, line: UInt = #line) {
        var maxDifference = 0
        var paddingWrites = 0
        for y in 0 ..< height {
            for x in 0 ..< width * 4 {
                maxDifference = max(maxDifference, abs(Int(expected[y * bytesPerRow + x]) - Int(actual[y * bytesPerRow + x])))
            }
            for x in width * 4 ..< bytesPerRow where actual[y * bytesPerRow + x] != sentinel {
                paddingWrites += 1
            }
        }
        XCTAssertEqual(maxDifference, 0, "\(width)x\(height)", file: file, line: line)
        XCTAssertEqual(paddingWrites, 0, "\(width)x\(height)", file: file, line: line)
    }

    func testCompactYuvaToBgraMatchesStepByStepConversion() {
        var random = Random(state: 1)
        for (width, height) in self.sizes {
            let alphaRowBytes = (width + 1) / 2
            var yuva = [UInt8](repeating: 0, count: width * height * 2 + alphaRowBytes * height)
            for i in 0 ..< width * height * 2 {
                yuva[i] = random.next()
            }
            for i in width * height * 2 ..< yuva.count {
                yuva[i] = random.nextAlpha(i)
            }
            let bytesPerRow = (width * 4 + 4 + 63) & ~63
            var expected = [UInt8](repeating: sentinel, count: bytesPerRow * height)
            var actual = expected
            yuva.withUnsafeBufferPointer { source in
                expected.withUnsafeMutableBufferPointer { dest in
                    referenceDecodeYUVAToRGBA(source.baseAddress!, dest.baseAddress!, width: width, height: height, bytesPerRow: bytesPerRow)
                }
                actual.withUnsafeMutableBufferPointer { dest in
                    decodeYUVAToRGBA(source.baseAddress!, dest.baseAddress!, Int32(width), Int32(height), Int32(bytesPerRow))
                }
            }
            self.compare(expected, actual, width: width, height: height, bytesPerRow: bytesPerRow)
        }
    }

    func testYuvaPlanesToBgraMatchesStepByStepConversion() {
        var random = Random(state: 2)
        for (width, height) in self.sizes {
            for hasAlpha in [false, true] {
                for unpremultiply in [false, true] {
                    // Strides wider than the rows, like FFmpeg's aligned line sizes.
                    let yStride = width + 32
                    let chromaStride = width / 2 + 16
                    var yPlane = [UInt8](repeating: 0, count: yStride * height)
                    var alpha = [UInt8](repeating: 0, count: yStride * height)
                    var cb = [UInt8](repeating: 0, count: chromaStride * height)
                    var cr = cb
                    for i in 0 ..< yPlane.count {
                        yPlane[i] = random.next()
                        alpha[i] = random.nextAlpha(i)
                    }
                    for i in 0 ..< cb.count {
                        cb[i] = random.next()
                        cr[i] = random.next()
                    }
                    let bytesPerRow = (width * 4 + 4 + 63) & ~63
                    var expected = [UInt8](repeating: sentinel, count: bytesPerRow * height)
                    var actual = expected
                    yPlane.withUnsafeBufferPointer { yPlane in
                        cb.withUnsafeBufferPointer { cb in
                            cr.withUnsafeBufferPointer { cr in
                                alpha.withUnsafeBufferPointer { alpha in
                                    expected.withUnsafeMutableBufferPointer { dest in
                                        referenceDecodeYUVAPlanesToRGBA(y: yPlane.baseAddress!, yStride: yStride, cb: cb.baseAddress!, cbStride: chromaStride, cr: cr.baseAddress!, crStride: chromaStride, hasAlpha: hasAlpha, alpha: alpha.baseAddress!, argb: dest.baseAddress!, width: width, height: height, bytesPerRow: bytesPerRow, unpremultiply: unpremultiply)
                                    }
                                    actual.withUnsafeMutableBufferPointer { dest in
                                        decodeYUVAPlanesToRGBA(yPlane.baseAddress!, Int32(yStride), cb.baseAddress!, Int32(chromaStride), cr.baseAddress!, Int32(chromaStride), hasAlpha, alpha.baseAddress!, dest.baseAddress!, Int32(width), Int32(height), Int32(bytesPerRow), unpremultiply)
                                    }
                                }
                            }
                        }
                    }
                    self.compare(expected, actual, width: width, height: height, bytesPerRow: bytesPerRow)
                }
            }
        }
    }
}
