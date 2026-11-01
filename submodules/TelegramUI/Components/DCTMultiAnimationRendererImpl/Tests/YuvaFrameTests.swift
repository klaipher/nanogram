import Foundation
import UIKit
import XCTest
import Accelerate
import CoreVideo
import IOSurface
import AnimationCache
@testable import DCTMultiAnimationRendererImpl

private struct Planes {
    let y: AnimationCacheItemFrame.Plane
    let u: AnimationCacheItemFrame.Plane
    let v: AnimationCacheItemFrame.Plane
    let a: AnimationCacheItemFrame.Plane
}

// Planes as the DCT cache stores them: full range, BT.709, premultiplied, Cb in `v` and Cr in `u`.
private func makePlanes(width: Int, height: Int, seed: UInt64) -> Planes {
    var state = seed
    func next() -> UInt8 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 33)
    }
    var y = Data(count: width * height)
    var a = Data(count: width * height)
    for i in 0 ..< width * height {
        let alpha: UInt8 = i % 7 == 0 ? 0 : (i % 5 == 0 ? 255 : next())
        a[i] = alpha
        // Premultiplied luma never exceeds alpha.
        y[i] = UInt8(Int(next()) * Int(alpha) / 255)
    }
    var u = Data(count: width / 2 * height / 2)
    var v = Data(count: width / 2 * height / 2)
    for i in 0 ..< u.count {
        u[i] = 96 &+ next() % 64
        v[i] = 96 &+ next() % 64
    }
    return Planes(
        y: AnimationCacheItemFrame.Plane(data: y, width: width, height: height, bytesPerRow: width),
        u: AnimationCacheItemFrame.Plane(data: u, width: width / 2, height: height / 2, bytesPerRow: width / 2),
        v: AnimationCacheItemFrame.Plane(data: v, width: width / 2, height: height / 2, bytesPerRow: width / 2),
        a: AnimationCacheItemFrame.Plane(data: a, width: width, height: height, bytesPerRow: width)
    )
}

private func generateConversion(fullRange: Bool) -> vImage_YpCbCrToARGB {
    var info = vImage_YpCbCrToARGB()
    var range = fullRange
        ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 1, CbCrMax: 255, CbCrMin: 0)
        : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
    vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &range, &info, kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, 0)
    return info
}

// What the image path shows: combineYUVAPlanesIntoARGB of the cache planes, as BGRA.
private let fullRangeConversion = generateConversion(fullRange: true)

private func rgbaFromCachePlanes(_ planes: Planes) -> Data {
    let width = planes.y.width, height = planes.y.height
    var info = fullRangeConversion
    var result = Data(count: width * height * 4)
    planes.y.data.withUnsafeBytes { y in
        planes.u.data.withUnsafeBytes { u in
            planes.v.data.withUnsafeBytes { v in
                result.withUnsafeMutableBytes { out in
                    var srcY = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: y.baseAddress!), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                    var srcCb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: v.baseAddress!), height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2), rowBytes: width / 2)
                    var srcCr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: u.baseAddress!), height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2), rowBytes: width / 2)
                    var dest = vImage_Buffer(data: out.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    let permuteMap: [UInt8] = [3, 2, 1, 0]
                    vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&srcY, &srcCb, &srcCr, &dest, &info, permuteMap, 255, vImage_Flags(kvImageDoNotTile))
                }
            }
        }
    }
    return result
}

// The YUVA surface read back as BGRA with the matrix and range it is labelled with.
private func rgbaFromVideoRangeBuffer(_ pixelBuffer: CVPixelBuffer) -> [UInt8] {
    let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
    var info = generateConversion(fullRange: false)
    var result = [UInt8](repeating: 0, count: width * height * 4)
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }
    result.withUnsafeMutableBytes { out in
        var srcY = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
        var srcCbCr = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1), height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))
        var dest = vImage_Buffer(data: out.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        let permuteMap: [UInt8] = [3, 2, 1, 0]
        vImageConvert_420Yp8_CbCr8ToARGB8888(&srcY, &srcCbCr, &dest, &info, permuteMap, 255, vImage_Flags(kvImageDoNotTile))
    }
    return result
}

final class YuvaFrameTests: XCTestCase {
    func testYuvaFrameIsVideoRangeWithTheBT709Matrix() throws {
        let planes = makePlanes(width: 96, height: 64, seed: 3)
        let frame = try XCTUnwrap(ItemAnimationContext.Frame(frame: AnimationCacheItemFrame(format: .yuva(y: planes.y, u: planes.u, v: planes.v, a: planes.a), duration: 1.0 / 30.0)))
        let pixelBuffer = try XCTUnwrap(frame.contentsAsCVPixelBuffer)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixelBuffer), kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(pixelBuffer))
        let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
        XCTAssertEqual(matrix as? String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let aPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 2)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let aStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 2)
        var wrong = 0
        for row in 0 ..< 64 {
            for column in 0 ..< 96 {
                let y = Double(planes.y.data[row * 96 + column])
                if Int(yPlane[row * yStride + column]) != Int((16.0 + y * 219.0 / 255.0).rounded()) {
                    wrong += 1
                }
                if aPlane[row * aStride + column] != planes.a.data[row * 96 + column] {
                    wrong += 1
                }
            }
        }
        for row in 0 ..< 32 {
            for column in 0 ..< 48 {
                let cb = Double(planes.v.data[row * 48 + column])
                let cr = Double(planes.u.data[row * 48 + column])
                if Int(cbcrPlane[row * cbcrStride + column * 2]) != Int((128.0 + (cb - 128.0) * 224.0 / 255.0).rounded()) {
                    wrong += 1
                }
                if Int(cbcrPlane[row * cbcrStride + column * 2 + 1]) != Int((128.0 + (cr - 128.0) * 224.0 / 255.0).rounded()) {
                    wrong += 1
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        XCTAssertEqual(wrong, 0)
    }

    // Decoded with its labels, the surface shows the colours of the image path within rounding.
    func testYuvaFrameColorsMatchTheImagePath() throws {
        for size in [64, 128, 256] {
            let planes = makePlanes(width: size, height: size, seed: UInt64(size))
            let frame = try XCTUnwrap(ItemAnimationContext.Frame(frame: AnimationCacheItemFrame(format: .yuva(y: planes.y, u: planes.u, v: planes.v, a: planes.a), duration: 1.0 / 30.0)))
            let pixelBuffer = try XCTUnwrap(frame.contentsAsCVPixelBuffer)
            let expected = rgbaFromCachePlanes(planes)
            let actual = rgbaFromVideoRangeBuffer(pixelBuffer)
            var maxDifference = 0
            for i in 0 ..< expected.count where i % 4 != 3 {
                maxDifference = max(maxDifference, abs(Int(expected[i]) - Int(actual[i])))
            }
            XCTAssertLessThanOrEqual(maxDifference, 2, "\(size)")
        }
    }

    // Frames come from a pool: after a frame is released its surface is used again.
    func testYuvaSurfacesAreReused() throws {
        let planes = makePlanes(width: 160, height: 160, seed: 9)
        var surfaceIds = Set<IOSurfaceID>()
        for _ in 0 ..< 20 {
            autoreleasepool {
                let frame = ItemAnimationContext.Frame(frame: AnimationCacheItemFrame(format: .yuva(y: planes.y, u: planes.u, v: planes.v, a: planes.a), duration: 1.0 / 30.0))
                if let pixelBuffer = frame?.contentsAsCVPixelBuffer, let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
                    surfaceIds.insert(IOSurfaceGetID(surface))
                }
            }
        }
        XCTAssertGreaterThan(surfaceIds.count, 0)
        XCTAssertLessThanOrEqual(surfaceIds.count, 3)
    }

    func testMismatchedPlanesAreRejected() {
        let planes = makePlanes(width: 64, height: 64, seed: 1)
        let short = AnimationCacheItemFrame.Plane(data: Data(count: 10), width: 64, height: 64, bytesPerRow: 64)
        XCTAssertNil(ItemAnimationContext.Frame(frame: AnimationCacheItemFrame(format: .yuva(y: short, u: planes.u, v: planes.v, a: planes.a), duration: 1.0)))
        XCTAssertNil(ItemAnimationContext.Frame(frame: AnimationCacheItemFrame(format: .yuva(y: planes.y, u: planes.u, v: planes.v, a: short), duration: 1.0)))
    }

    // Cost per frame of each display path, printed for the report (debug build, simulator).
    func testBenchmarkFramePreparation() throws {
        for size in [64, 96, 160, 256, 384, 512] {
            let planes = makePlanes(width: size, height: size, seed: 5)
            let yuvaFrame = AnimationCacheItemFrame(format: .yuva(y: planes.y, u: planes.u, v: planes.v, a: planes.a), duration: 1.0)
            let iterations = 200
            var bestImage = Double.greatestFiniteMagnitude
            var bestYuva = Double.greatestFiniteMagnitude
            for _ in 0 ..< 5 {
                var start = CACurrentMediaTime()
                for _ in 0 ..< iterations {
                    autoreleasepool {
                        // The image path converts to RGBA in the cache, then copies it into an image.
                        let rgba = rgbaFromCachePlanes(planes)
                        _ = ItemAnimationContext.Frame(frame: AnimationCacheItemFrame(format: .rgba(data: rgba, width: size, height: size, bytesPerRow: size * 4), duration: 1.0))
                    }
                }
                bestImage = min(bestImage, (CACurrentMediaTime() - start) / Double(iterations))
                start = CACurrentMediaTime()
                for _ in 0 ..< iterations {
                    autoreleasepool {
                        _ = ItemAnimationContext.Frame(frame: yuvaFrame)
                    }
                }
                bestYuva = min(bestYuva, (CACurrentMediaTime() - start) / Double(iterations))
            }
            print(String(format: "YUVA_BENCH %3d px: image path %.1f us, pooled yuva %.1f us", size, bestImage * 1e6, bestYuva * 1e6))
        }
    }
}
