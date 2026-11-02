import Foundation
import CoreVideo
import Accelerate
import TelegramCore
import YuvConversion
import VP9Hardware

// A VP9 decoder that a video sticker frame source can use instead of libvpx.
protocol VideoStickerHardwareDecoder: AnyObject {
    func decode(_ frame: WebMStickerFrame) -> VP9DecodedFrame?
    func reset()
    func invalidate()
}

extension VP9HardwareFrameDecoder: VideoStickerHardwareDecoder {
}

final class VideoStickerHardwareStream {
    let frames: [WebMStickerFrame]
    let decoder: VideoStickerHardwareDecoder
    var nextFrameIndex = 0

    init(frames: [WebMStickerFrame], decoder: VideoStickerHardwareDecoder) {
        self.frames = frames
        self.decoder = decoder
    }
}

// Runs once per process, on the first video sticker that is decoded, and is logged once.
let videoStickerVP9HardwareProbe: VP9HardwareProbeResult = {
    let result = VP9HardwareDecoding.probe()
    Logger.shared.log("VideoSticker", result.description)
    return result
}()

// Hardware decoding is used only when the probe found a hardware VP9 decoder and the file is a
// plain VP9 WebM; everything else keeps libvpx. Tests replace this.
var makeVideoStickerHardwareStream: (String) -> VideoStickerHardwareStream? = { path in
    guard videoStickerVP9HardwareProbe.hasHardwareDecoder else {
        return nil
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), let sticker = WebMStickerDemuxer.parse(data) else {
        return nil
    }
    guard let decoder = VP9HardwareFrameDecoder(sticker: sticker) else {
        return nil
    }
    return VideoStickerHardwareStream(frames: sticker.frames, decoder: decoder)
}

// Turns a decoded frame into premultiplied (or unpremultiplied) BGRA with the same conversion the libvpx path uses
// (decodeYUVAPlanesToRGBA, BT.601 video range), so both give the same pixels.
final class VideoStickerHardwareFrameConverter {
    private var cb: [UInt8] = []
    private var cr: [UInt8] = []
    private var alpha: [UInt8] = []
    private var bgra: [UInt8] = []

    // `unpremultiply` matches a libvpx reader opened with unpremultiplyAlpha (the frame cache).
    func convert(_ frame: VP9DecodedFrame, unpremultiply: Bool = false, _ f: (UnsafeRawPointer, Int, Int, Int) -> Void) -> Bool {
        let color = frame.color
        guard CVPixelBufferGetPlaneCount(color) == 2 else {
            return false
        }
        let width = CVPixelBufferGetWidth(color)
        let height = CVPixelBufferGetHeight(color)
        guard width > 0, height > 0, width <= WebMStickerDemuxer.maxDimension, height <= WebMStickerDemuxer.maxDimension else {
            return false
        }
        guard CVPixelBufferLockBaseAddress(color, .readOnly) == kCVReturnSuccess else {
            return false
        }
        defer {
            CVPixelBufferUnlockBaseAddress(color, .readOnly)
        }
        if let alpha = frame.alpha {
            guard CVPixelBufferLockBaseAddress(alpha, .readOnly) == kCVReturnSuccess else {
                return false
            }
        }
        defer {
            if let alpha = frame.alpha {
                CVPixelBufferUnlockBaseAddress(alpha, .readOnly)
            }
        }
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(color, 0), let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(color, 1) else {
            return false
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(color, 0)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(color, 1)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        guard CVPixelBufferGetWidthOfPlane(color, 1) >= chromaWidth, CVPixelBufferGetHeightOfPlane(color, 1) >= chromaHeight, cbcrStride >= chromaWidth * 2, yStride >= width else {
            return false
        }

        // Interleaved CbCr into separate planes.
        let chromaCount = chromaWidth * chromaHeight
        if self.cb.count != chromaCount {
            self.cb = [UInt8](repeating: 0, count: chromaCount)
            self.cr = [UInt8](repeating: 0, count: chromaCount)
        }
        let deinterleaved: Bool = self.cb.withUnsafeMutableBytes { cbBytes in
            return self.cr.withUnsafeMutableBytes { crBytes in
                guard let cbBase = cbBytes.baseAddress, let crBase = crBytes.baseAddress else {
                    return false
                }
                var cbBuffer = vImage_Buffer(data: cbBase, height: vImagePixelCount(chromaHeight), width: vImagePixelCount(chromaWidth), rowBytes: chromaWidth)
                var crBuffer = vImage_Buffer(data: crBase, height: vImagePixelCount(chromaHeight), width: vImagePixelCount(chromaWidth), rowBytes: chromaWidth)
                return withUnsafePointer(to: &cbBuffer) { cbPointer in
                    return withUnsafePointer(to: &crBuffer) { crPointer in
                        var sources: [UnsafeRawPointer?] = [UnsafeRawPointer(cbcrPlane), UnsafeRawPointer(cbcrPlane.advanced(by: 1))]
                        var destinations: [UnsafePointer<vImage_Buffer>?] = [cbPointer, crPointer]
                        return vImageConvert_ChunkyToPlanar8(&sources, &destinations, 2, 2, vImagePixelCount(chromaWidth), vImagePixelCount(chromaHeight), cbcrStride, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
                    }
                }
            }
        }
        guard deinterleaved else {
            return false
        }

        // decodeYUVAPlanesToRGBA reads alpha with the stride of the Y plane.
        var alphaPointer: UnsafeRawPointer?
        if let alpha = frame.alpha {
            guard CVPixelBufferGetWidth(alpha) == width, CVPixelBufferGetHeight(alpha) == height, let alphaPlane = CVPixelBufferGetBaseAddressOfPlane(alpha, 0) else {
                return false
            }
            let alphaStride = CVPixelBufferGetBytesPerRowOfPlane(alpha, 0)
            guard alphaStride >= width else {
                return false
            }
            if alphaStride == yStride {
                alphaPointer = UnsafeRawPointer(alphaPlane)
            } else {
                if self.alpha.count != yStride * height {
                    self.alpha = [UInt8](repeating: 0, count: yStride * height)
                }
                self.alpha.withUnsafeMutableBytes { bytes in
                    guard let base = bytes.baseAddress else {
                        return
                    }
                    for row in 0 ..< height {
                        memcpy(base.advanced(by: row * yStride), alphaPlane.advanced(by: row * alphaStride), width)
                    }
                }
            }
        }

        let bytesPerRow = width * 4
        if self.bgra.count != bytesPerRow * height {
            self.bgra = [UInt8](repeating: 0, count: bytesPerRow * height)
        }
        let hasAlpha = frame.alpha != nil
        let copiedAlpha = hasAlpha && alphaPointer == nil
        let scratchAlpha = self.alpha
        let cb = self.cb
        let cr = self.cr
        return self.bgra.withUnsafeMutableBytes { bgraBytes -> Bool in
            guard let bgraBase = bgraBytes.baseAddress else {
                return false
            }
            return cb.withUnsafeBytes { cbBytes -> Bool in
                return cr.withUnsafeBytes { crBytes -> Bool in
                    return scratchAlpha.withUnsafeBytes { scratchAlphaBytes -> Bool in
                        guard let cbBase = cbBytes.baseAddress, let crBase = crBytes.baseAddress else {
                            return false
                        }
                        let alphaSource: UnsafeRawPointer? = copiedAlpha ? scratchAlphaBytes.baseAddress : alphaPointer
                        if hasAlpha && alphaSource == nil {
                            return false
                        }
                        decodeYUVAPlanesToRGBA(
                            yPlane.assumingMemoryBound(to: UInt8.self), Int32(clamping: yStride),
                            cbBase.assumingMemoryBound(to: UInt8.self), Int32(clamping: chromaWidth),
                            crBase.assumingMemoryBound(to: UInt8.self), Int32(clamping: chromaWidth),
                            hasAlpha, alphaSource?.assumingMemoryBound(to: UInt8.self),
                            bgraBase.assumingMemoryBound(to: UInt8.self),
                            Int32(clamping: width), Int32(clamping: height), Int32(clamping: bytesPerRow),
                            unpremultiply
                        )
                        f(UnsafeRawPointer(bgraBase), width, height, bytesPerRow)
                        return true
                    }
                }
            }
        }
    }
}
