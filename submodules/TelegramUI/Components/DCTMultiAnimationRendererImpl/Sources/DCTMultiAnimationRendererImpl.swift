import Foundation
import UIKit
import SwiftSignalKit
import Display
import AnimationCache
import MultiAnimationRenderer
import Accelerate
import IOSurface

final class LoadFrameGroupTask {
    let task: () -> () -> Void
    let queueAffinity: Int

    init(task: @escaping () -> () -> Void, queueAffinity: Int) {
        self.task = task
        self.queueAffinity = queueAffinity
    }
}

// Every cached animation is at most 30 fps (lottie is cached at every other frame of 60).
// A frame lasting a whole number of 1/30 s shows at the same moments with a 30 Hz tick,
// so the 60 Hz tick is only kept while some item needs it.
func animationFrameDurationNeedsHighTickRate(_ duration: Double) -> Bool {
    let ticks = duration * 30.0
    return abs(ticks - ticks.rounded()) > 0.01 || ticks.rounded() < 1.0
}

// Starts a repeating tick on the main thread and returns a function that stops it.
// Tests pass a manual one, so frame counts do not depend on wall-clock time.
struct DCTAnimationTickScheduler {
    // The tick gets the elapsed time since the previous one, in seconds.
    let start: (_ interval: Double, _ tick: @escaping (_ elapsed: Double) -> Void) -> () -> Void

    static let runLoopTimer = DCTAnimationTickScheduler(start: { interval, tick in
        final class TimerTarget: NSObject {
            private let f: (Double) -> Void
            private let interval: Double

            init(interval: Double, _ f: @escaping (Double) -> Void) {
                self.interval = interval
                self.f = f
            }

            @objc func timerEvent() {
                self.f(self.interval)
            }
        }
        let timer = Foundation.Timer(timeInterval: interval, target: TimerTarget(interval: interval, tick), selector: #selector(TimerTarget.timerEvent), userInfo: nil, repeats: true)
        // Apple's guidance for energy: a tolerance lets the system batch this wake-up
        // with others. 10% of a frame is below what can be seen.
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        return {
            timer.invalidate()
        }
    })
}

private var yuvToRgbConversion: vImage_YpCbCrToARGB = {
    var info = vImage_YpCbCrToARGB()
    var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
    vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &pixelRange, &info, kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, 0)
    return info
}()

// The cache's own conversion (combineYUVAPlanesIntoARGB in ImageDCT).
private var fullRangeYuvToRgbConversion: vImage_YpCbCrToARGB = {
    var info = vImage_YpCbCrToARGB()
    var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 1, CbCrMax: 255, CbCrMin: 0)
    vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &pixelRange, &info, kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, 0)
    return info
}()

// The cache stores full-range BT.709 YUV with premultiplied alpha. 'v0a8' (the only 4:2:0 format
// with alpha) is video range, so the values are remapped, and the matrix is attached; without it
// Core Animation assumes BT.601.
private let fullToVideoRangeLuma: [UInt8] = (0 ... 255).map { value in
    return UInt8(clamping: Int((16.0 + Double(value) * 219.0 / 255.0).rounded()))
}
private let fullToVideoRangeChroma: [UInt8] = (0 ... 255).map { value in
    return UInt8(clamping: Int((128.0 + (Double(value) - 128.0) * 224.0 / 255.0).rounded()))
}

// One pool per frame size; buffers return to it when Core Animation and the frame let go of them.
final class YuvaPixelBufferPools {
    static let shared = YuvaPixelBufferPools()

    private struct Key: Hashable {
        let width: Int
        let height: Int
    }

    private let lock = NSLock()
    private var pools: [Key: CVPixelBufferPool] = [:]

    func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else {
            return nil
        }
        let key = Key(width: width, height: height)
        self.lock.lock()
        var pool = self.pools[key]
        if pool == nil {
            if self.pools.count >= 16 {
                self.pools.removeAll()
            }
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            self.pools[key] = created
        }
        self.lock.unlock()
        guard let pool else {
            return nil
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let pixelBuffer else {
            return nil
        }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return pixelBuffer
    }
}

func makeVideoRangeYuvaPixelBuffer(y: AnimationCacheItemFrame.Plane, u: AnimationCacheItemFrame.Plane, v: AnimationCacheItemFrame.Plane, a: AnimationCacheItemFrame.Plane) -> CVPixelBuffer? {
    guard y.width > 0, y.height > 0, a.width == y.width, a.height == y.height, u.width == v.width, u.height == v.height, u.width >= y.width / 2, u.height >= y.height / 2 else {
        return nil
    }
    guard y.bytesPerRow >= y.width, a.bytesPerRow >= a.width, u.bytesPerRow >= u.width, v.bytesPerRow >= v.width else {
        return nil
    }
    guard y.data.count >= y.bytesPerRow * y.height, a.data.count >= a.bytesPerRow * a.height, u.data.count >= u.bytesPerRow * u.height, v.data.count >= v.bytesPerRow * v.height else {
        return nil
    }
    guard let pixelBuffer = YuvaPixelBufferPools.shared.makeBuffer(width: y.width, height: y.height) else {
        return nil
    }
    guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
        return nil
    }
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
    guard let baseAddressY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0), let baseAddressCbCr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1), let baseAddressA = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 2) else {
        return nil
    }
    let chromaWidth = y.width / 2
    let chromaHeight = y.height / 2
    var dstY = vImage_Buffer(data: baseAddressY, height: vImagePixelCount(y.height), width: vImagePixelCount(y.width), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
    var dstCbCr = vImage_Buffer(data: baseAddressCbCr, height: vImagePixelCount(chromaHeight), width: vImagePixelCount(chromaWidth * 2), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))
    let dstARowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 2)

    var ok = true
    y.data.withUnsafeBytes { yBytes in
        guard let base = yBytes.baseAddress else {
            ok = false
            return
        }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(y.height), width: vImagePixelCount(y.width), rowBytes: y.bytesPerRow)
        ok = ok && vImageTableLookUp_Planar8(&src, &dstY, fullToVideoRangeLuma, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
    }
    a.data.withUnsafeBytes { aBytes in
        guard let base = aBytes.baseAddress else {
            ok = false
            return
        }
        for row in 0 ..< a.height {
            memcpy(baseAddressA.advanced(by: row * dstARowBytes), base.advanced(by: row * a.bytesPerRow), a.width)
        }
    }
    u.data.withUnsafeBytes { uBytes in
        v.data.withUnsafeBytes { vBytes in
            guard let uBase = uBytes.baseAddress, let vBase = vBytes.baseAddress else {
                ok = false
                return
            }
            // The cache's v plane is Cb and its u plane is Cr (see combineYUVAPlanesIntoARGB).
            var sourceU = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: uBase), height: vImagePixelCount(chromaHeight), width: vImagePixelCount(chromaWidth), rowBytes: u.bytesPerRow)
            var sourceV = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: vBase), height: vImagePixelCount(chromaHeight), width: vImagePixelCount(chromaWidth), rowBytes: v.bytesPerRow)
            withUnsafePointer(to: &sourceV) { sourceV in
                withUnsafePointer(to: &sourceU) { sourceU in
                    var srcPlanarBuffers: [UnsafePointer<vImage_Buffer>?] = [sourceV, sourceU]
                    var destChannels: [UnsafeMutableRawPointer?] = [baseAddressCbCr, baseAddressCbCr.advanced(by: 1)]
                    ok = ok && vImageConvert_PlanarToChunky8(&srcPlanarBuffers, &destChannels, 2, 2, vImagePixelCount(chromaWidth), vImagePixelCount(chromaHeight), dstCbCr.rowBytes, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
                }
            }
        }
    }
    ok = ok && vImageTableLookUp_Planar8(&dstCbCr, &dstCbCr, fullToVideoRangeChroma, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
    return ok ? pixelBuffer : nil
}

// Items smaller than this (pixels) always use images when useYuvA is on.
let yuvaMinimumPixelSize: CGFloat = 128.0

final class ItemAnimationContext {
    final class Frame {
        let frame: AnimationCacheItemFrame
        let duration: Double

        let contentsAsImage: UIImage?
        let contentsAsCVPixelBuffer: CVPixelBuffer?

        let size: CGSize

        var remainingDuration: Double

        private var blurredRepresentationValue: UIImage?

        // Badges made on the main thread (cache misses there), for tests.
        static var mainThreadBlurredRepresentationBuildsForTesting: Int = 0

        init?(frame: AnimationCacheItemFrame) {
            self.frame = frame
            self.duration = frame.duration
            self.remainingDuration = frame.duration

            switch frame.format {
            case let .rgba(data, width, height, bytesPerRow):
                guard let context = DrawingContext(size: CGSize(width: CGFloat(width), height: CGFloat(height)), scale: 1.0, opaque: false, bytesPerRow: bytesPerRow) else {
                    return nil
                }

                data.withUnsafeBytes { bytes -> Void in
                    memcpy(context.bytes, bytes.baseAddress!, height * bytesPerRow)
                }

                guard let image = context.generateImage() else {
                    return nil
                }

                self.contentsAsImage = image
                self.contentsAsCVPixelBuffer = nil
                self.size = CGSize(width: CGFloat(width), height: CGFloat(height))
            case let .yuva(y, u, v, a):
                guard let pixelBuffer = makeVideoRangeYuvaPixelBuffer(y: y, u: u, v: v, a: a) else {
                    return nil
                }
                self.contentsAsImage = nil
                self.contentsAsCVPixelBuffer = pixelBuffer
                self.size = CGSize(width: CGFloat(y.width), height: CGFloat(y.height))
            }
        }

        // What to put in a target's contents. A target that draws only alpha (MultiAnimationRenderTarget.
        // contentsAlphaIsMask) never gets the YUVA surface: Core Animation reads its alpha as 1 under the
        // "AAAA" swizzle. Frames for such targets are normally loaded as images; this covers a YUVA frame
        // that was already loaded when the target was added or its tint was set.
        func contents(alphaIsMask: Bool) -> AnyObject? {
            if let image = self.contentsAsImage {
                return image.cgImage
            }
            if alphaIsMask {
                return self.imageFromYuva()
            }
            return self.contentsAsCVPixelBuffer
        }

        private var imageFromYuvaValue: CGImage?

        // The cache planes as the image path shows them (combineYUVAPlanesIntoARGB: full range, BT.709,
        // premultiplied), made once per frame.
        private func imageFromYuva() -> CGImage? {
            if let imageFromYuvaValue = self.imageFromYuvaValue {
                return imageFromYuvaValue
            }
            guard case let .yuva(y, u, v, a) = self.frame.format else {
                return nil
            }
            guard let context = DrawingContext(size: CGSize(width: CGFloat(y.width), height: CGFloat(y.height)), scale: 1.0, opaque: false) else {
                return nil
            }
            var destination = vImage_Buffer(data: context.bytes, height: vImagePixelCount(y.height), width: vImagePixelCount(y.width), rowBytes: context.bytesPerRow)
            var ok = true
            y.data.withUnsafeBytes { yBytes in
                u.data.withUnsafeBytes { uBytes in
                    v.data.withUnsafeBytes { vBytes in
                        a.data.withUnsafeBytes { aBytes in
                            guard let yBase = yBytes.baseAddress, let uBase = uBytes.baseAddress, let vBase = vBytes.baseAddress, let aBase = aBytes.baseAddress else {
                                ok = false
                                return
                            }
                            var sourceY = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: yBase), height: vImagePixelCount(y.height), width: vImagePixelCount(y.width), rowBytes: y.bytesPerRow)
                            // The cache's v plane is Cb and its u plane is Cr.
                            var sourceCb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: vBase), height: vImagePixelCount(y.height / 2), width: vImagePixelCount(y.width / 2), rowBytes: v.bytesPerRow)
                            var sourceCr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: uBase), height: vImagePixelCount(y.height / 2), width: vImagePixelCount(y.width / 2), rowBytes: u.bytesPerRow)
                            var sourceA = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: aBase), height: vImagePixelCount(a.height), width: vImagePixelCount(a.width), rowBytes: a.bytesPerRow)
                            let permuteMap: [UInt8] = [3, 2, 1, 0]
                            ok = ok && vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&sourceY, &sourceCb, &sourceCr, &destination, &fullRangeYuvToRgbConversion, permuteMap, 255, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
                            // BGRA in memory: alpha is the fourth channel.
                            ok = ok && vImageOverwriteChannels_ARGB8888(&sourceA, &destination, &destination, 0x1, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
                        }
                    }
                }
            }
            guard ok else {
                return nil
            }
            self.imageFromYuvaValue = context.generateImage()?.cgImage
            return self.imageFromYuvaValue
        }

        func blurredRepresentation(color: UIColor?) -> UIImage? {
            if let blurredRepresentationValue = self.blurredRepresentationValue {
                return blurredRepresentationValue
            }
            if Thread.isMainThread {
                Frame.mainThreadBlurredRepresentationBuildsForTesting += 1
            }

            switch frame.format {
            case let .rgba(data, width, height, bytesPerRow):
                let blurredWidth = 12
                let blurredHeight = 12
                guard let context = DrawingContext(size: CGSize(width: CGFloat(blurredWidth), height: CGFloat(blurredHeight)), scale: 1.0, opaque: true, bytesPerRow: bytesPerRow) else {
                    return nil
                }

                let size = CGSize(width: CGFloat(blurredWidth), height: CGFloat(blurredHeight))

                data.withUnsafeBytes { bytes -> Void in
                    if let dataProvider = CGDataProvider(dataInfo: nil, data: bytes.baseAddress!, size: bytes.count, releaseData: { _, _, _ in }) {
                        let image = CGImage(
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bitsPerPixel: 32,
                            bytesPerRow: bytesPerRow,
                            space: DeviceGraphicsContextSettings.shared.colorSpace,
                            bitmapInfo: DeviceGraphicsContextSettings.shared.transparentBitmapInfo,
                            provider: dataProvider,
                            decode: nil,
                            shouldInterpolate: true,
                            intent: .defaultIntent
                        )
                        if let image = image {
                            context.withFlippedContext { c in
                                c.setFillColor((color ?? .white).cgColor)
                                c.fill(CGRect(origin: CGPoint(), size: size))
                                c.draw(image, in: CGRect(origin: CGPoint(x: -size.width / 2.0, y: -size.height / 2.0), size: CGSize(width: size.width * 1.8, height: size.height * 1.8)))
                            }
                        }
                    }

                    var destinationBuffer = vImage_Buffer()
                    destinationBuffer.width = UInt(blurredWidth)
                    destinationBuffer.height = UInt(blurredHeight)
                    destinationBuffer.data = context.bytes
                    destinationBuffer.rowBytes = context.bytesPerRow

                    vImageBoxConvolve_ARGB8888(&destinationBuffer,
                                               &destinationBuffer,
                                               nil,
                                               0, 0,
                                               UInt32(15),
                                               UInt32(15),
                                               nil,
                                               vImage_Flags(kvImageTruncateKernel))

                    let divisor: Int32 = 0x1000

                    let rwgt: CGFloat = 0.3086
                    let gwgt: CGFloat = 0.6094
                    let bwgt: CGFloat = 0.0820

                    let adjustSaturation: CGFloat = 1.7

                    let a = (1.0 - adjustSaturation) * rwgt + adjustSaturation
                    let b = (1.0 - adjustSaturation) * rwgt
                    let c = (1.0 - adjustSaturation) * rwgt
                    let d = (1.0 - adjustSaturation) * gwgt
                    let e = (1.0 - adjustSaturation) * gwgt + adjustSaturation
                    let f = (1.0 - adjustSaturation) * gwgt
                    let g = (1.0 - adjustSaturation) * bwgt
                    let h = (1.0 - adjustSaturation) * bwgt
                    let i = (1.0 - adjustSaturation) * bwgt + adjustSaturation

                    let satMatrix: [CGFloat] = [
                        a, b, c, 0,
                        d, e, f, 0,
                        g, h, i, 0,
                        0, 0, 0, 1
                    ]

                    var matrix: [Int16] = satMatrix.map { value in
                        return Int16(value * CGFloat(divisor))
                    }

                    vImageMatrixMultiply_ARGB8888(&destinationBuffer, &destinationBuffer, &matrix, divisor, nil, nil, vImage_Flags(kvImageDoNotTile))

                    context.withFlippedContext { c in
                        c.setFillColor((color ?? .white).withMultipliedAlpha(0.6).cgColor)
                        c.fill(CGRect(origin: CGPoint(), size: size))
                    }
                }

                self.blurredRepresentationValue = context.generateImage()
                return self.blurredRepresentationValue
            case let .yuva(y, u, v, a):
                let blurredWidth = 12
                let blurredHeight = 12
                let size = CGSize(width: blurredWidth, height: blurredHeight)

                var sourceY = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: y.data.withUnsafeBytes { $0.baseAddress! }),
                    height: vImagePixelCount(y.height),
                    width: vImagePixelCount(y.width),
                    rowBytes: y.bytesPerRow
                )

                var sourceU = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: u.data.withUnsafeBytes { $0.baseAddress! }),
                    height: vImagePixelCount(u.height),
                    width: vImagePixelCount(u.width),
                    rowBytes: u.bytesPerRow
                )

                var sourceV = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: v.data.withUnsafeBytes { $0.baseAddress! }),
                    height: vImagePixelCount(v.height),
                    width: vImagePixelCount(v.width),
                    rowBytes: v.bytesPerRow
                )

                var sourceA = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: a.data.withUnsafeBytes { $0.baseAddress! }),
                    height: vImagePixelCount(a.height),
                    width: vImagePixelCount(a.width),
                    rowBytes: a.bytesPerRow
                )

                let scaledYData = malloc(blurredWidth * blurredHeight)!
                defer {
                    free(scaledYData)
                }

                let scaledUData = malloc(blurredWidth * blurredHeight / 4)!
                defer {
                    free(scaledUData)
                }

                let scaledVData = malloc(blurredWidth * blurredHeight / 4)!
                defer {
                    free(scaledVData)
                }

                let scaledAData = malloc(blurredWidth * blurredHeight)!
                defer {
                    free(scaledAData)
                }

                var scaledY = vImage_Buffer(
                    data: scaledYData,
                    height: vImagePixelCount(blurredHeight),
                    width: vImagePixelCount(blurredWidth),
                    rowBytes: blurredWidth
                )

                var scaledU = vImage_Buffer(
                    data: scaledUData,
                    height: vImagePixelCount(blurredHeight / 2),
                    width: vImagePixelCount(blurredWidth / 2),
                    rowBytes: blurredWidth / 2
                )

                var scaledV = vImage_Buffer(
                    data: scaledVData,
                    height: vImagePixelCount(blurredHeight / 2),
                    width: vImagePixelCount(blurredWidth / 2),
                    rowBytes: blurredWidth / 2
                )

                var scaledA = vImage_Buffer(
                    data: scaledAData,
                    height: vImagePixelCount(blurredHeight),
                    width: vImagePixelCount(blurredWidth),
                    rowBytes: blurredWidth
                )

                vImageScale_Planar8(&sourceY, &scaledY, nil, vImage_Flags(kvImageHighQualityResampling))
                vImageScale_Planar8(&sourceU, &scaledU, nil, vImage_Flags(kvImageHighQualityResampling))
                vImageScale_Planar8(&sourceV, &scaledV, nil, vImage_Flags(kvImageHighQualityResampling))
                vImageScale_Planar8(&sourceA, &scaledA, nil, vImage_Flags(kvImageHighQualityResampling))

                guard let context = DrawingContext(size: size, scale: 1.0, clear: true) else {
                    return nil
                }

                var destinationBuffer = vImage_Buffer(
                    data: context.bytes,
                    height: vImagePixelCount(blurredHeight),
                    width: vImagePixelCount(blurredWidth),
                    rowBytes: context.bytesPerRow
                )

                var result = kvImageNoError

                var permuteMap: [UInt8] = [1, 2, 3, 0]
                result = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&scaledY, &scaledU, &scaledV, &destinationBuffer, &yuvToRgbConversion, &permuteMap, 255, vImage_Flags(kvImageDoNotTile))
                if result != kvImageNoError {
                    return nil
                }

                result = vImageOverwriteChannels_ARGB8888(&scaledA, &destinationBuffer, &destinationBuffer, 1 << 0, vImage_Flags(kvImageDoNotTile));
                if result != kvImageNoError {
                    return nil
                }

                vImageBoxConvolve_ARGB8888(&destinationBuffer,
                                           &destinationBuffer,
                                           nil,
                                           0, 0,
                                           UInt32(15),
                                           UInt32(15),
                                           nil,
                                           vImage_Flags(kvImageTruncateKernel))

                let divisor: Int32 = 0x1000

                let rwgt: CGFloat = 0.3086
                let gwgt: CGFloat = 0.6094
                let bwgt: CGFloat = 0.0820

                let adjustSaturation: CGFloat = 1.7

                let a = (1.0 - adjustSaturation) * rwgt + adjustSaturation
                let b = (1.0 - adjustSaturation) * rwgt
                let c = (1.0 - adjustSaturation) * rwgt
                let d = (1.0 - adjustSaturation) * gwgt
                let e = (1.0 - adjustSaturation) * gwgt + adjustSaturation
                let f = (1.0 - adjustSaturation) * gwgt
                let g = (1.0 - adjustSaturation) * bwgt
                let h = (1.0 - adjustSaturation) * bwgt
                let i = (1.0 - adjustSaturation) * bwgt + adjustSaturation

                let satMatrix: [CGFloat] = [
                    a, b, c, 0,
                    d, e, f, 0,
                    g, h, i, 0,
                    0, 0, 0, 1
                ]

                var matrix: [Int16] = satMatrix.map { value in
                    return Int16(value * CGFloat(divisor))
                }

                vImageMatrixMultiply_ARGB8888(&destinationBuffer, &destinationBuffer, &matrix, divisor, nil, nil, vImage_Flags(kvImageDoNotTile))

                context.withFlippedContext { c in
                    c.setFillColor((color ?? .white).withMultipliedAlpha(0.6).cgColor)
                    c.fill(CGRect(origin: CGPoint(), size: size))
                }

                self.blurredRepresentationValue = context.generateImage()
                return self.blurredRepresentationValue
            }
        }
    }

    static let queue0 = Queue(name: "ItemAnimationContext-0", qos: .default)
    static let queue1 = Queue(name: "ItemAnimationContext-1", qos: .default)

    private let useYuvA: Bool

    private let cache: AnimationCache
    let queueAffinity: Int
    private let stateUpdated: () -> Void

    private var disposable: Disposable?
    private var displayLink: ConstantDisplayLinkAnimator?
    private var item: Atomic<AnimationCacheItem>?
    private var itemPlaceholderAndFrameIndex: (UIImage, Int)?

    private var currentFrame: Frame? {
        didSet {
            let needsHighTickRate = self.currentFrame.flatMap { animationFrameDurationNeedsHighTickRate($0.duration) } ?? false
            if self.needsHighTickRate != needsHighTickRate {
                self.needsHighTickRate = needsHighTickRate
                self.stateUpdated()
            }
        }
    }
    private(set) var needsHighTickRate: Bool = false
    private var loadingFrameTaskId: Int?
    private var nextLoadingFrameTaskId: Int = 0

    private(set) var isPlaying: Bool = false {
        didSet {
            if self.isPlaying != oldValue {
                self.stateUpdated()
            }
        }
    }

    let targets = Bag<Weak<MultiAnimationRenderTarget>>()

    init(cache: AnimationCache, queueAffinity: Int, itemId: String, size: CGSize, useYuvA: Bool, fetch: @escaping (AnimationCacheFetchOptions) -> Disposable, stateUpdated: @escaping () -> Void) {
        self.cache = cache
        self.queueAffinity = queueAffinity
        // Small emoji gain nothing from a YUVA surface (measured), so they keep the image path.
        self.useYuvA = useYuvA && min(size.width, size.height) >= yuvaMinimumPixelSize
        self.stateUpdated = stateUpdated

        self.disposable = cache.get(sourceId: itemId, size: size, fetch: fetch).start(next: { [weak self] result in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                if let item = result.item {
                    strongSelf.item = Atomic(value: item)
                }
                if let (placeholder, index) = strongSelf.itemPlaceholderAndFrameIndex {
                    strongSelf.itemPlaceholderAndFrameIndex = nil
                    strongSelf.setFrameIndex(index: index, placeholder: placeholder)
                }
                strongSelf.updateIsPlaying()
                strongSelf.showFirstFrameIfNothingDrawsOne()
            }
        })
    }

    // An item that does not play gets frames only from the tick, which never runs for it. Its
    // targets normally have their first frame from `loadFirstFrame`; one whose load ended without a
    // frame (the first-frame conversion failed, or found no item) stayed empty although the full
    // conversion arrived here. Such a target gets frame 0, once, from the item.
    private func showFirstFrameIfNothingDrawsOne() {
        guard let item = self.item, self.currentFrame == nil, !self.isPlaying, self.loadingFrameTaskId == nil else {
            return
        }
        var needsFrame = false
        for target in self.targets.copyItems() {
            if let target = target.value, target.needsFrame {
                needsFrame = true
                break
            }
        }
        guard needsFrame else {
            return
        }

        let taskId = self.nextLoadingFrameTaskId
        self.nextLoadingFrameTaskId += 1
        self.loadingFrameTaskId = taskId

        let queue = self.queueAffinity % 2 == 0 ? ItemAnimationContext.queue0 : ItemAnimationContext.queue1
        queue.async { [weak self] in
            let frame = item.with { item -> Frame? in
                item.reset()
                return item.advance(advance: .frames(1), requestedFormat: .rgba).flatMap { Frame(frame: $0.frame) }
            }
            Queue.mainQueue().async {
                guard let self, self.loadingFrameTaskId == taskId else {
                    return
                }
                self.loadingFrameTaskId = nil
                guard let frame, self.currentFrame == nil else {
                    return
                }
                self.currentFrame = frame
                for target in self.targets.copyItems() {
                    if let target = target.value, target.needsFrame {
                        ItemAnimationContext.show(frame, on: target, didLoop: false)
                        if let blurredRepresentationTarget = target.blurredRepresentationTarget {
                            blurredRepresentationTarget.contents = frame.blurredRepresentation(color: target.blurredRepresentationBackgroundColor)?.cgImage
                        }
                    }
                }
            }
        }
    }

    deinit {
        self.disposable?.dispose()
        self.displayLink?.invalidate()
    }

    func setFrameIndex(index: Int, placeholder: UIImage) {
        if let item = self.item {
            let nextFrame = item.with { item -> AnimationCacheItemFrame? in
                item.reset()
                for i in 0 ... index {
                    let result = item.advance(advance: .frames(1), requestedFormat: .rgba)
                    if i == index {
                        return result?.frame
                    }
                }
                return nil
            }

            self.loadingFrameTaskId = nil

            if let nextFrame = nextFrame, let currentFrame = Frame(frame: nextFrame) {
                self.currentFrame = currentFrame

                for target in self.targets.copyItems() {
                    if let target = target.value {
                        ItemAnimationContext.show(currentFrame, on: target, didLoop: false)

                        if let blurredRepresentationTarget = target.blurredRepresentationTarget {
                            blurredRepresentationTarget.contents = currentFrame.blurredRepresentation(color: target.blurredRepresentationBackgroundColor)?.cgImage
                        }
                    }
                }
            }
        } else {
            for target in self.targets.copyItems() {
                if let target = target.value {
                    target.transitionToContents(placeholder.cgImage!, didLoop: false)
                }
            }

            self.itemPlaceholderAndFrameIndex = (placeholder, index)
        }
    }

    static func show(_ frame: Frame, on target: MultiAnimationRenderTarget, didLoop: Bool) {
        if let contents = frame.contents(alphaIsMask: target.contentsAlphaIsMask) {
            target.transitionToContents(contents, didLoop: didLoop)
        }
    }

    func updateAddedTarget(target: MultiAnimationRenderTarget) {
        if let currentFrame = self.currentFrame {
            ItemAnimationContext.show(currentFrame, on: target, didLoop: false)

            if let blurredRepresentationTarget = target.blurredRepresentationTarget {
                blurredRepresentationTarget.contents = currentFrame.blurredRepresentation(color: target.blurredRepresentationBackgroundColor)?.cgImage
            }
        }

        self.updateIsPlaying()
        self.showFirstFrameIfNothingDrawsOne()
    }

    // A target's tint was set or cleared (contentsAlphaIsMask). A YUVA frame it already shows is replaced
    // with an image; a stopped animation brings no next frame to do it.
    func updateContentsMode(target: MultiAnimationRenderTarget) {
        guard target.contentsAlphaIsMask, let currentFrame = self.currentFrame, currentFrame.contentsAsCVPixelBuffer != nil else {
            return
        }
        guard let contents = currentFrame.contents(alphaIsMask: true) else {
            return
        }
        if let current = target.contents as AnyObject?, current === contents {
            return
        }
        target.transitionToContents(contents, didLoop: false)
    }

    func updateIsPlaying() {
        var isPlaying = true
        if self.item == nil {
            isPlaying = false
        }

        var shouldBeAnimating = false
        for target in self.targets.copyItems() {
            if let target = target.value {
                if target.shouldBeAnimating {
                    shouldBeAnimating = true
                    break
                }
            }
        }
        if !shouldBeAnimating {
            isPlaying = false
        }

        self.isPlaying = isPlaying
    }

    func animationTick(advanceTimestamp: Double) -> LoadFrameGroupTask? {
        return self.update(advanceTimestamp: advanceTimestamp)
    }

    private func update(advanceTimestamp: Double) -> LoadFrameGroupTask? {
        guard let item = self.item else {
            return nil
        }

        var frameAdvance: AnimationCacheItem.Advance?
        if self.loadingFrameTaskId == nil {
            if let currentFrame = self.currentFrame, advanceTimestamp > 0.0 {
                let divisionFactor = advanceTimestamp / currentFrame.remainingDuration
                let wholeFactor = round(divisionFactor)
                if abs(wholeFactor - divisionFactor) < 0.005 {
                    currentFrame.remainingDuration = 0.0
                    frameAdvance = .frames(Int(wholeFactor))
                } else {
                    currentFrame.remainingDuration -= advanceTimestamp
                    if currentFrame.remainingDuration <= 0.0 {
                        frameAdvance = .duration(currentFrame.duration + max(0.0, -currentFrame.remainingDuration))
                    }
                }
            } else if self.currentFrame == nil {
                frameAdvance = .frames(1)
            }
        }

        if let frameAdvance = frameAdvance, self.loadingFrameTaskId == nil {
            let taskId = self.nextLoadingFrameTaskId
            self.nextLoadingFrameTaskId += 1

            self.loadingFrameTaskId = taskId
            // A target that draws only alpha (a tinted template emoji) cannot show a YUVA surface, so while
            // one is attached the item loads images for all of its targets.
            var useYuvA = self.useYuvA
            if useYuvA {
                for target in self.targets.copyItems() {
                    if let target = target.value, target.contentsAlphaIsMask {
                        useYuvA = false
                        break
                    }
                }
            }
            // Locked premium emoji show a blurred badge made from every frame (a 12x12 draw, box blur and
            // saturation matrix). It is made here with the frame, on the loading queue, so main only assigns it;
            // made on main it took about 5% of the main thread while the emoji panel was open. Same colour choice
            // as the main-thread path: the first target that shows a badge.
            var blurredRepresentationColor: UIColor??
            for target in self.targets.copyItems() {
                if let target = target.value, target.blurredRepresentationTarget != nil {
                    blurredRepresentationColor = .some(target.blurredRepresentationBackgroundColor)
                    break
                }
            }

            return LoadFrameGroupTask(task: { [weak self] in
                let currentFrame: (frame: Frame, didLoop: Bool)?
                do {
                    if let (frame, didLoop) = try item.tryWith({ item -> (AnimationCacheItemFrame, Bool)? in
                        let defaultFormat: AnimationCacheItemFrame.RequestedFormat
                        if useYuvA {
                            defaultFormat = .yuva(rowAlignment: 1)
                        } else {
                            defaultFormat = .rgba
                        }

                        if let result = item.advance(advance: frameAdvance, requestedFormat: defaultFormat) {
                            return (result.frame, result.didLoop)
                        } else {
                            return nil
                        }
                    }), let mappedFrame = Frame(frame: frame) {
                        currentFrame = (mappedFrame, didLoop)
                    } else {
                        currentFrame = nil
                    }
                } catch {
                    assertionFailure()
                    currentFrame = nil
                }
                if let currentFrame, let blurredRepresentationColor {
                    let _ = currentFrame.frame.blurredRepresentation(color: blurredRepresentationColor)
                }

                return {
                    guard let strongSelf = self else {
                        return
                    }

                    if strongSelf.loadingFrameTaskId != taskId {
                        return
                    }

                    strongSelf.loadingFrameTaskId = nil

                    if let currentFrame = currentFrame {
                        strongSelf.currentFrame = currentFrame.frame
                        for target in strongSelf.targets.copyItems() {
                            if let target = target.value {
                                ItemAnimationContext.show(currentFrame.frame, on: target, didLoop: currentFrame.didLoop)

                                if let blurredRepresentationTarget = target.blurredRepresentationTarget {
                                    blurredRepresentationTarget.contents = currentFrame.frame.blurredRepresentation(color: target.blurredRepresentationBackgroundColor)?.cgImage
                                }
                            }
                        }
                    }
                }
            }, queueAffinity: self.queueAffinity)
        }

        if let _ = self.currentFrame {
            for target in self.targets.copyItems() {
                if let target = target.value {
                    target.updateDisplayPlaceholder(displayPlaceholder: false)
                }
            }
        }

        return nil
    }
}

public final class DCTMultiAnimationRendererImpl: MultiAnimationRenderer {
    private final class GroupContext {
        private let firstFrameQueue: Queue
        private let stateUpdated: () -> Void

        private struct ItemKey: Hashable {
            var id: String
            var width: Int
            var height: Int
            var uniqueId: Int
        }

        private var itemContexts: [ItemKey: ItemAnimationContext] = [:]
        private var nextQueueAffinity: Int = 0
        private var nextUniqueId: Int = 1

        private(set) var isPlaying: Bool = false {
            didSet {
                if self.isPlaying != oldValue {
                    self.stateUpdated()
                }
            }
        }
        private(set) var needsHighTickRate: Bool = false {
            didSet {
                if self.needsHighTickRate != oldValue {
                    self.stateUpdated()
                }
            }
        }

        init(firstFrameQueue: Queue, stateUpdated: @escaping () -> Void) {
            self.firstFrameQueue = firstFrameQueue
            self.stateUpdated = stateUpdated
        }

        func add(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, unique: Bool, size: CGSize, useYuvA: Bool, fetch: @escaping (AnimationCacheFetchOptions) -> Disposable) -> Disposable {
            var uniqueId = 0
            if unique {
                uniqueId = self.nextUniqueId
                self.nextUniqueId += 1
            }

            let itemKey = ItemKey(id: itemId, width: Int(size.width), height: Int(size.height), uniqueId: uniqueId)
            let itemContext: ItemAnimationContext
            if let current = self.itemContexts[itemKey] {
                itemContext = current
            } else {
                let queueAffinity = self.nextQueueAffinity
                self.nextQueueAffinity += 1
                itemContext = ItemAnimationContext(cache: cache, queueAffinity: queueAffinity, itemId: itemId, size: size, useYuvA: useYuvA, fetch: fetch, stateUpdated: { [weak self] in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.updateIsPlaying()
                })
                self.itemContexts[itemKey] = itemContext
            }

            let index = itemContext.targets.add(Weak(target))
            itemContext.updateAddedTarget(target: target)

            let deinitIndex = target.deinitCallbacks.add { [weak self, weak itemContext] in
                Queue.mainQueue().async {
                    guard let strongSelf = self, let itemContext = itemContext, strongSelf.itemContexts[itemKey] === itemContext else {
                        return
                    }
                    itemContext.targets.remove(index)
                    if itemContext.targets.isEmpty {
                        strongSelf.itemContexts.removeValue(forKey: itemKey)
                        // Without this the timer kept ticking after the last item was gone.
                        strongSelf.updateIsPlaying()
                    }
                }
            }

            let updateStateIndex = target.updateStateCallbacks.add { [weak itemContext, weak target] in
                guard let itemContext = itemContext else {
                    return
                }
                itemContext.updateIsPlaying()
                if let target, target.contentsAlphaIsMask {
                    // Next turn: the tint may be set from inside the target's own transitionToContents,
                    // which then assigns the frame it was given.
                    Queue.mainQueue().justDispatch { [weak itemContext, weak target] in
                        guard let itemContext, let target else {
                            return
                        }
                        itemContext.updateContentsMode(target: target)
                    }
                }
            }

            return ActionDisposable { [weak self, weak itemContext, weak target] in
                guard let strongSelf = self, let itemContext = itemContext, strongSelf.itemContexts[itemKey] === itemContext else {
                    return
                }
                if let target = target {
                    target.deinitCallbacks.remove(deinitIndex)
                    target.updateStateCallbacks.remove(updateStateIndex)
                }
                itemContext.targets.remove(index)
                if itemContext.targets.isEmpty {
                    strongSelf.itemContexts.removeValue(forKey: itemKey)
                    strongSelf.updateIsPlaying()
                }
            }.strict()
        }

        func loadFirstFrameSynchronously(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize) -> Bool {
            if let item = cache.getFirstFrameSynchronously(sourceId: itemId, size: size) {
                guard let frame = item.advance(advance: .frames(1), requestedFormat: .rgba) else {
                    return false
                }
                guard let loadedFrame = ItemAnimationContext.Frame(frame: frame.frame) else {
                    return false
                }

                if let contents = loadedFrame.contents(alphaIsMask: target.contentsAlphaIsMask) {
                    target.contents = contents
                }
                target.numFrames = item.numFrames

                if let blurredRepresentationTarget = target.blurredRepresentationTarget {
                    blurredRepresentationTarget.contents = loadedFrame.blurredRepresentation(color: target.blurredRepresentationBackgroundColor)?.cgImage
                }

                return true
            } else {
                return false
            }
        }

        func loadFirstFrame(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (Bool, Bool) -> Void) -> Disposable {
            var hadIntermediateUpdate = false
            return cache.getFirstFrame(queue: self.firstFrameQueue, sourceId: itemId, size: size, fetch: fetch, completion: { [weak target] item in
                guard let item = item.item else {
                    let isFinal = item.isFinal
                    hadIntermediateUpdate = true
                    Queue.mainQueue().async {
                        completion(false, isFinal)
                    }
                    return
                }

                let loadedFrame: ItemAnimationContext.Frame?
                if let frame = item.advance(advance: .frames(1), requestedFormat: .rgba) {
                    loadedFrame = ItemAnimationContext.Frame(frame: frame.frame)
                } else {
                    loadedFrame = nil
                }

                Queue.mainQueue().async {
                    guard let target = target else {
                        completion(false, true)
                        return
                    }
                    target.numFrames = item.numFrames
                    if let loadedFrame = loadedFrame {
                        if let contents = loadedFrame.contents(alphaIsMask: target.contentsAlphaIsMask) {
                            if hadIntermediateUpdate {
                                target.transitionToContents(contents, didLoop: false)
                            } else {
                                target.contents = contents
                            }
                        }

                        if let blurredRepresentationTarget = target.blurredRepresentationTarget {
                            blurredRepresentationTarget.contents = loadedFrame.blurredRepresentation(color: target.blurredRepresentationBackgroundColor)?.cgImage
                        }

                        completion(true, true)
                    } else {
                        completion(false, true)
                    }
                }
            }).strict()
        }

        func loadFirstFrameAsImage(cache: AnimationCache, itemId: String, size: CGSize, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (CGImage?) -> Void) -> Disposable {
            return cache.getFirstFrame(queue: self.firstFrameQueue, sourceId: itemId, size: size, fetch: fetch, completion: { item in
                guard let item = item.item else {
                    Queue.mainQueue().async {
                        completion(nil)
                    }
                    return
                }

                let loadedFrame: ItemAnimationContext.Frame?
                if let frame = item.advance(advance: .frames(1), requestedFormat: .rgba) {
                    loadedFrame = ItemAnimationContext.Frame(frame: frame.frame)
                } else {
                    loadedFrame = nil
                }

                Queue.mainQueue().async {
                    if let loadedFrame = loadedFrame {
                        if let cgImage = loadedFrame.contentsAsImage?.cgImage {
                            completion(cgImage)
                        } else {
                            completion(nil)
                        }
                    } else {
                        completion(nil)
                    }
                }
            }).strict()
        }

        func setFrameIndex(itemId: String, size: CGSize, frameIndex: Int, placeholder: UIImage) {
            if let itemContext = self.itemContexts[ItemKey(id: itemId, width: Int(size.width), height: Int(size.height), uniqueId: 0)] {
                itemContext.setFrameIndex(index: frameIndex, placeholder: placeholder)
            }
        }

        private func updateIsPlaying() {
            var isPlaying = false
            var needsHighTickRate = false
            for (_, itemContext) in self.itemContexts {
                if itemContext.isPlaying {
                    isPlaying = true
                    if itemContext.needsHighTickRate {
                        needsHighTickRate = true
                        break
                    }
                }
            }

            self.isPlaying = isPlaying
            self.needsHighTickRate = needsHighTickRate
        }

        func animationTick(advanceTimestamp: Double) -> [LoadFrameGroupTask] {
            var tasks: [LoadFrameGroupTask] = []
            for (_, itemContext) in self.itemContexts {
                if itemContext.isPlaying {
                    if let task = itemContext.animationTick(advanceTimestamp: advanceTimestamp) {
                        tasks.append(task)
                    }
                }
            }

            return tasks
        }
    }

    public static let firstFrameQueue = Queue(name: "DCTMultiAnimationRenderer-FirstFrame", qos: .userInteractive)

    public var useYuvA: Bool = false
    private var groupContext: GroupContext?
    private var frameSkip: Int
    private let tickScheduler: DCTAnimationTickScheduler
    private var stopDisplayTimer: (() -> Void)?
    private var pendingFrameLoads: Int = 0
    private var isInBackground: Bool = false
    private var applicationStateObservers: [NSObjectProtocol] = []

    private(set) var isPlaying: Bool = false
    private var needsHighTickRate: Bool = false
    private var displayTimerInterval: Double?

    // The tick interval in use, nil while stopped.
    var currentTickIntervalForTesting: Double? {
        return self.displayTimerInterval
    }

    // Ticks whose frames have not reached the targets yet.
    var pendingFrameLoadsForTesting: Int {
        return self.pendingFrameLoads
    }

    private func updateDisplayTimer() {
        var frameInterval: Double?
        if self.isPlaying {
            let frameSkip = self.needsHighTickRate ? self.frameSkip : 2
            frameInterval = Double(frameSkip) / 60.0
        }
        if self.displayTimerInterval == frameInterval {
            return
        }
        self.displayTimerInterval = frameInterval
        if let stopDisplayTimer = self.stopDisplayTimer {
            self.stopDisplayTimer = nil
            stopDisplayTimer()
        }
        guard let frameInterval else {
            return
        }
        self.stopDisplayTimer = self.tickScheduler.start(frameInterval, { [weak self] elapsed in
            guard let strongSelf = self else {
                return
            }
            strongSelf.animationTick(advance: elapsed)
        })
    }

    public convenience init() {
        self.init(tickScheduler: .sharedDisplayLink)
    }

    init(tickScheduler: DCTAnimationTickScheduler) {
        self.tickScheduler = tickScheduler
        self.frameSkip = DCTAnimationTickPolicy.frameSkip(isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: ProcessInfo.processInfo.thermalState, processorCount: ProcessInfo.processInfo.processorCount)

        // Audio can keep the app running in the background, where frames are decoded for nobody.
        // Emoji keep their frame and continue from it on return.
        self.applicationStateObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: { [weak self] _ in
                guard let self else {
                    return
                }
                self.isInBackground = true
                self.updateIsPlaying()
            }),
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil, using: { [weak self] _ in
                guard let self else {
                    return
                }
                self.isInBackground = false
                self.updateIsPlaying()
            }),
            // Low Power Mode and the thermal state change while the app runs.
            NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: { [weak self] _ in
                self?.updatePowerStateFromProcessInfo()
            }),
            NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
                self?.updatePowerStateFromProcessInfo()
            })
        ]
    }

    private func updatePowerStateFromProcessInfo() {
        self.updatePowerState(isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: ProcessInfo.processInfo.thermalState)
    }

    // Moves the tick to the rate the power state allows; an unchanged rate leaves the tick running.
    func updatePowerState(isLowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) {
        let frameSkip = DCTAnimationTickPolicy.frameSkip(isLowPowerMode: isLowPowerMode, thermalState: thermalState, processorCount: ProcessInfo.processInfo.processorCount)
        if self.frameSkip == frameSkip {
            return
        }
        self.frameSkip = frameSkip
        self.updateDisplayTimer()
    }

    deinit {
        for observer in self.applicationStateObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        // The run loop retains a scheduled timer, so it would keep firing after the renderer is gone.
        if let stopDisplayTimer = self.stopDisplayTimer {
            Queue.mainQueue().async {
                stopDisplayTimer()
            }
        }
    }

    public func add(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, unique: Bool, size: CGSize, fetch: @escaping (AnimationCacheFetchOptions) -> Disposable) -> Disposable {
        let groupContext: GroupContext
        if let current = self.groupContext {
            groupContext = current
        } else {
            groupContext = GroupContext(firstFrameQueue: DCTMultiAnimationRendererImpl.firstFrameQueue, stateUpdated: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updateIsPlaying()
            })
            self.groupContext = groupContext
        }

        let disposable = groupContext.add(target: target, cache: cache, itemId: itemId, unique: unique, size: size, useYuvA: self.useYuvA, fetch: fetch)

        return ActionDisposable {
            disposable.dispose()
        }.strict()
    }

    public func loadFirstFrameSynchronously(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize) -> Bool {
        let groupContext: GroupContext
        if let current = self.groupContext {
            groupContext = current
        } else {
            groupContext = GroupContext(firstFrameQueue: DCTMultiAnimationRendererImpl.firstFrameQueue, stateUpdated: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updateIsPlaying()
            })
            self.groupContext = groupContext
        }

        return groupContext.loadFirstFrameSynchronously(target: target, cache: cache, itemId: itemId, size: size)
    }

    public func loadFirstFrame(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (Bool, Bool) -> Void) -> Disposable {
        let groupContext: GroupContext
        if let current = self.groupContext {
            groupContext = current
        } else {
            groupContext = GroupContext(firstFrameQueue: DCTMultiAnimationRendererImpl.firstFrameQueue, stateUpdated: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updateIsPlaying()
            })
            self.groupContext = groupContext
        }

        return groupContext.loadFirstFrame(target: target, cache: cache, itemId: itemId, size: size, fetch: fetch, completion: completion).strict()
    }

    public func loadFirstFrameAsImage(cache: AnimationCache, itemId: String, size: CGSize, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (CGImage?) -> Void) -> Disposable {
        let groupContext: GroupContext
        if let current = self.groupContext {
            groupContext = current
        } else {
            groupContext = GroupContext(firstFrameQueue: DCTMultiAnimationRendererImpl.firstFrameQueue, stateUpdated: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updateIsPlaying()
            })
            self.groupContext = groupContext
        }

        return groupContext.loadFirstFrameAsImage(cache: cache, itemId: itemId, size: size, fetch: fetch, completion: completion).strict()
    }

    public func setFrameIndex(itemId: String, size: CGSize, frameIndex: Int, placeholder: UIImage) {
        if let groupContext = self.groupContext {
            groupContext.setFrameIndex(itemId: itemId, size: size, frameIndex: frameIndex, placeholder: placeholder)
        }
    }

    private func updateIsPlaying() {
        var isPlaying = false
        var needsHighTickRate = false
        if let groupContext = self.groupContext {
            if groupContext.isPlaying {
                isPlaying = true
                needsHighTickRate = groupContext.needsHighTickRate
            }
        }

        self.isPlaying = isPlaying && !self.isInBackground
        self.needsHighTickRate = needsHighTickRate
        self.updateDisplayTimer()
    }

    private func animationTick(advance: Double) {
        let secondsPerFrame = advance

        var tasks: [LoadFrameGroupTask] = []
        if let groupContext = self.groupContext {
            if groupContext.isPlaying {
                tasks.append(contentsOf: groupContext.animationTick(advanceTimestamp: secondsPerFrame))
            }
        }

        if !tasks.isEmpty {
            let tasks0 = tasks.filter { $0.queueAffinity % 2 == 0 }
            let tasks1 = tasks.filter { $0.queueAffinity % 2 == 1 }
            let allTasks = [tasks0, tasks1]

            let taskCompletions = Atomic<[Int: [() -> Void]]>(value: [:])
            let queues: [Queue] = [ItemAnimationContext.queue0, ItemAnimationContext.queue1]
            self.pendingFrameLoads += 1

            for i in 0 ..< 2 {
                let partTasks = allTasks[i]
                let id = i
                queues[i].async { [weak self] in
                    var completions: [() -> Void] = []
                    for task in partTasks {
                        let complete = task.task()
                        completions.append(complete)
                    }

                    var complete = false
                    let _ = taskCompletions.modify { current in
                        var current = current
                        current[id] = completions
                        if current.count == 2 {
                            complete = true
                        }
                        return current
                    }

                    if complete {
                        Queue.mainQueue().async { [weak self] in
                            let allCompletions = taskCompletions.with { $0 }
                            for (_, fs) in allCompletions {
                                for f in fs {
                                    f()
                                }
                            }
                            self?.pendingFrameLoads -= 1
                        }
                    }
                }
            }
        }
    }
}
