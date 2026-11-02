import Foundation
import CoreMedia
import Compression
import Display
import YuvConversion
import UniversalMediaPlayer

// The frame file of a CachedVideoStickerRepresentation (the `.cached` playback mode), read by
// AnimatedStickerCachedFrameSource: a header of Int32s (fps, frame count, width, height, bytes per
// row), then per frame an Int32 length and the LZFSE-compressed XOR delta of the frame's YUVA bytes
// against the previous frame.
//
// LZFSE stays: on these deltas (mostly zeros) LZ4 encodes 22x faster but decodes 1.8x slower and
// is 34% larger, and every displayed frame is decoded again on each loop, so the one-off encode
// saving is lost after ~700 played frames (VideoStickerFrameCacheTests.testCodecCost).

// Encodes BGRA frames into the cache format.
private final class VideoStickerFrameCacheEncoder {
    private let size: CGSize
    private let bytesPerRow: Int
    private let yuvaLength: Int
    private var yuvaFrameData: UnsafeMutableRawPointer
    private var previousYuvaFrameData: UnsafeMutableRawPointer
    private var compressedFrameData: Data
    private let scratchData: UnsafeMutableRawPointer
    private let frameCountOffset = 4
    private(set) var output = Data()
    private(set) var frameCount: Int32 = 0

    init(size: CGSize, fps: Int32) {
        self.size = size
        self.bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: Int(size.width))

        let frameLength = self.bytesPerRow * Int(size.height)
        assert(frameLength % 16 == 0)
        let yuvaPixelsPerAlphaRow = (Int(size.width) + 1) & (~1)
        self.yuvaLength = Int(size.width) * Int(size.height) * 2 + yuvaPixelsPerAlphaRow * Int(size.height) / 2
        self.yuvaFrameData = UnsafeMutableRawPointer.allocate(byteCount: self.yuvaLength, alignment: 16)
        memset(self.yuvaFrameData, 0, self.yuvaLength)
        self.previousYuvaFrameData = UnsafeMutableRawPointer.allocate(byteCount: self.yuvaLength, alignment: 16)
        memset(self.previousYuvaFrameData, 0, self.yuvaLength)
        self.compressedFrameData = Data(count: frameLength)
        self.scratchData = UnsafeMutableRawPointer.allocate(byteCount: max(1, compression_encode_scratch_buffer_size(COMPRESSION_LZFSE)), alignment: 16)

        self.append(fps)
        self.append(0 as Int32)
        self.append(Int32(size.width))
        self.append(Int32(size.height))
        self.append(Int32(self.bytesPerRow))
    }

    deinit {
        self.yuvaFrameData.deallocate()
        self.previousYuvaFrameData.deallocate()
        self.scratchData.deallocate()
    }

    private func append(_ value: Int32) {
        var value = value
        withUnsafeBytes(of: &value) { self.output.append(contentsOf: $0) }
    }

    // A nil source re-encodes the previous frame's pixels, as the previous writer did.
    func add(source: UnsafeRawPointer?, width: Int, height: Int, bytesPerRow: Int) {
        if let source {
            resizeAndEncodeRGBAToYUVA(self.yuvaFrameData.assumingMemoryBound(to: UInt8.self), source.assumingMemoryBound(to: UInt8.self), Int32(self.size.width), Int32(self.size.height), Int32(self.bytesPerRow), Int32(width), Int32(height), Int32(bytesPerRow), false)
        }

        var lhs = self.previousYuvaFrameData.assumingMemoryBound(to: UInt64.self)
        var rhs = self.yuvaFrameData.assumingMemoryBound(to: UInt64.self)
        for _ in 0 ..< self.yuvaLength / 8 {
            lhs.pointee = rhs.pointee ^ lhs.pointee
            lhs = lhs.advanced(by: 1)
            rhs = rhs.advanced(by: 1)
        }
        var lhsRest = self.previousYuvaFrameData.assumingMemoryBound(to: UInt8.self).advanced(by: (self.yuvaLength / 8) * 8)
        var rhsRest = self.yuvaFrameData.assumingMemoryBound(to: UInt8.self).advanced(by: (self.yuvaLength / 8) * 8)
        for _ in (self.yuvaLength / 8) * 8 ..< self.yuvaLength {
            lhsRest.pointee = rhsRest.pointee ^ lhsRest.pointee
            lhsRest = lhsRest.advanced(by: 1)
            rhsRest = rhsRest.advanced(by: 1)
        }

        let compressedFrameDataLength = self.compressedFrameData.count
        let yuvaLength = self.yuvaLength
        let previous = self.previousYuvaFrameData
        let scratch = self.scratchData
        let length = self.compressedFrameData.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else {
                return 0
            }
            return compression_encode_buffer(base.assumingMemoryBound(to: UInt8.self), compressedFrameDataLength, previous.assumingMemoryBound(to: UInt8.self), yuvaLength, scratch, COMPRESSION_LZFSE)
        }
        self.append(Int32(length))
        self.output.append(self.compressedFrameData.prefix(length))

        let tmp = self.previousYuvaFrameData
        self.previousYuvaFrameData = self.yuvaFrameData
        self.yuvaFrameData = tmp
        self.frameCount += 1
    }

    // Records the frame count; like before, only when the whole stream was read.
    func finish(complete: Bool) -> Data {
        if complete && self.frameCount > 0 {
            var frameCount = self.frameCount
            let offset = self.frameCountOffset
            withUnsafeBytes(of: &frameCount) { bytes in
                self.output.replaceSubrange(offset ..< offset + 4, with: bytes)
            }
        }
        return self.output
    }
}

// Returns the cache file's bytes, or nil when cancelled.
public func makeVideoStickerFrameCache(path: String, size: CGSize, isCancelled: () -> Bool) -> Data? {
    // The frame rate comes from FFmpeg as before, for both decoders.
    let source = SoftwareVideoSource(path: path, hintVP9: true, unpremultiplyAlpha: true)
    if isCancelled() {
        return nil
    }
    let fps = Int32(min(30, source.getFramerate()))

    // Hardware VP9 when the device has it. Its planes equal libvpx's and are converted to BGRA by
    // the same decodeYUVAPlanesToRGBA (unpremultiplied, as the libvpx path asks for), so the file is
    // the same; on any failure the file is written again from libvpx.
    if let hardwareStream = makeVideoStickerHardwareStream(path) {
        let encoder = VideoStickerFrameCacheEncoder(size: size, fps: fps)
        let converter = VideoStickerHardwareFrameConverter()
        var failed = false
        for frame in hardwareStream.frames {
            if isCancelled() {
                hardwareStream.decoder.invalidate()
                return nil
            }
            guard let decoded = hardwareStream.decoder.decode(frame), converter.convert(decoded, unpremultiply: true, { source, width, height, bytesPerRow in
                encoder.add(source: source, width: width, height: height, bytesPerRow: bytesPerRow)
            }) else {
                failed = true
                break
            }
        }
        hardwareStream.decoder.invalidate()
        if !failed && !hardwareStream.frames.isEmpty {
            return encoder.finish(complete: true)
        }
    }

    let encoder = VideoStickerFrameCacheEncoder(size: size, fps: fps)
    var complete = false
    while true {
        let frameAndLoop = source.readFrame(maxPts: nil)
        guard let frame = frameAndLoop.0 else {
            complete = frameAndLoop.3
            break
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
            break
        }
        CVPixelBufferLockBaseAddress(imageBuffer, CVPixelBufferLockFlags(rawValue: 0))
        encoder.add(source: CVPixelBufferGetBaseAddress(imageBuffer).map(UnsafeRawPointer.init), width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer), bytesPerRow: CVPixelBufferGetBytesPerRow(imageBuffer))
        CVPixelBufferUnlockBaseAddress(imageBuffer, CVPixelBufferLockFlags(rawValue: 0))
    }
    return encoder.finish(complete: complete)
}
