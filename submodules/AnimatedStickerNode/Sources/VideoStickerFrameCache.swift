import Foundation
import CoreMedia
import Compression
import Display
import YuvConversion
import UniversalMediaPlayer
import ManagedFile
import VP9Hardware

// The frame file of a CachedVideoStickerRepresentation (the `.cached` playback mode), read by
// AnimatedStickerCachedFrameSource: a header of Int32s (fps, frame count, width, height, bytes per
// row), then per frame an Int32 length and the LZFSE-compressed XOR delta of the frame's YUVA bytes
// against the previous frame.
//
// LZFSE stays: on these deltas (mostly zeros) LZ4 encodes 22x faster but decodes 1.8x slower and
// is 34% larger, and every displayed frame is decoded again on each loop, so the one-off encode
// saving is lost after ~700 played frames (VideoStickerFrameCacheTests.testCodecCost).

// Encodes BGRA frames into the cache format, straight into a file: the compressed frames of a long sticker are
// never held in memory (several of these run at once while a pack opens).
private final class VideoStickerFrameCacheEncoder {
    private let size: CGSize
    private let bytesPerRow: Int
    private let yuvaLength: Int
    private var yuvaFrameData: UnsafeMutableRawPointer
    private var previousYuvaFrameData: UnsafeMutableRawPointer
    private var compressedFrameData: Data
    private let scratchData: UnsafeMutableRawPointer
    private let frameCountOffset = 4
    private let file: ManagedFile
    private(set) var frameCount: Int32 = 0
    // Set when a write to the file came up short (disk full); the file is then not a valid cache.
    private(set) var writeFailed = false

    // The file is written from its current position, which the caller leaves at the start.
    init(size: CGSize, fps: Int32, file: ManagedFile) {
        self.file = file
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
        if self.file.write(&value, count: 4) != 4 {
            self.writeFailed = true
        }
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
        if length > 0 {
            let written = self.compressedFrameData.withUnsafeBytes { bytes -> Int in
                guard let address = bytes.baseAddress else {
                    return 0
                }
                return self.file.write(address, count: length)
            }
            if written != length {
                self.writeFailed = true
            }
        }

        let tmp = self.previousYuvaFrameData
        self.previousYuvaFrameData = self.yuvaFrameData
        self.yuvaFrameData = tmp
        self.frameCount += 1
    }

    // Records the frame count in the header; like before, only when the whole stream was read. Returns false
    // when the file could not be written completely.
    func finish(complete: Bool) -> Bool {
        if complete && self.frameCount > 0 && !self.writeFailed {
            var frameCount = self.frameCount
            if self.file.seek(position: Int64(self.frameCountOffset)) {
                if self.file.write(&frameCount, count: 4) != 4 {
                    self.writeFailed = true
                }
            } else {
                self.writeFailed = true
            }
        }
        return !self.writeFailed
    }
}

/// The most frames a cache holds: a "video sticker" is a few seconds long, so a longer or faster file (which would
/// make the cache grow without bound while it is written) ends the cache early and is played from the source.
func videoStickerFrameCacheLimit(fps: Int32) -> Int {
    return min(WebMStickerDemuxer.maxFrameCount, (fps > 0 ? Int(fps) : 30) * 10)
}

// Writes the cache file for a video sticker to `outputPath`. False when cancelled or when the file could not be
// written (the partial file is removed). A stream longer than `videoStickerFrameCacheLimit` is written with a frame
// count of 0 (not usable), like any stream that was not read to its end.
public func makeVideoStickerFrameCache(path: String, size: CGSize, outputPath: String, isCancelled: () -> Bool) -> Bool {
    guard let file = ManagedFile(queue: nil, path: outputPath, mode: .readwrite) else {
        return false
    }
    file.truncate(count: 0)
    let success = writeVideoStickerFrameCache(path: path, size: size, file: file, isCancelled: isCancelled)
    if !success {
        file._unsafeClose()
        let _ = try? FileManager.default.removeItem(atPath: outputPath)
    }
    return success
}

private func writeVideoStickerFrameCache(path: String, size: CGSize, file: ManagedFile, isCancelled: () -> Bool) -> Bool {
    if isCancelled() {
        return false
    }
    // Hardware VP9 when the device has it. Its planes equal libvpx's and are converted to BGRA by
    // the same decodeYUVAPlanesToRGBA (unpremultiplied, as the libvpx path asks for), so the file is
    // the same; on any failure the file is written again from libvpx.
    var openedSource: SoftwareVideoSource?
    if let hardwareStream = makeVideoStickerHardwareStream(path) {
        // The frame rate comes from the container when it states one (what FFmpeg reports as well); FFmpeg is opened
        // only when it does not, or when the hardware decoder fails.
        let fps: Int32
        if let frameRate = hardwareStream.frameRate {
            fps = Int32(min(30, Int(frameRate)))
        } else {
            let opened = SoftwareVideoSource(path: path, hintVP9: true, unpremultiplyAlpha: true)
            openedSource = opened
            fps = Int32(min(30, opened.getFramerate()))
        }
        if isCancelled() {
            hardwareStream.decoder.invalidate()
            return false
        }
        let limit = videoStickerFrameCacheLimit(fps: fps)
        let encoder = VideoStickerFrameCacheEncoder(size: size, fps: fps, file: file)
        let converter = VideoStickerHardwareFrameConverter()
        var failed = false
        var exceededLimit = false
        for frame in hardwareStream.frames {
            if isCancelled() {
                hardwareStream.decoder.invalidate()
                return false
            }
            if Int(encoder.frameCount) >= limit {
                exceededLimit = true
                break
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
            return encoder.finish(complete: !exceededLimit)
        }
        // Start the file again from libvpx.
        file.truncate(count: 0)
        file.seek(position: 0)
    }

    // The frame rate comes from FFmpeg as before.
    let source = openedSource ?? SoftwareVideoSource(path: path, hintVP9: true, unpremultiplyAlpha: true)
    if isCancelled() {
        return false
    }
    let fps = Int32(min(30, source.getFramerate()))
    let limit = videoStickerFrameCacheLimit(fps: fps)
    let encoder = VideoStickerFrameCacheEncoder(size: size, fps: fps, file: file)
    var complete = false
    while true {
        if isCancelled() {
            return false
        }
        if Int(encoder.frameCount) >= limit {
            break
        }
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

// The cache file's bytes, or nil when cancelled or not writable (tests compare these).
func makeVideoStickerFrameCache(path: String, size: CGSize, isCancelled: () -> Bool) -> Data? {
    let outputPath = NSTemporaryDirectory() + "vsticker-cache-" + UUID().uuidString
    defer {
        let _ = try? FileManager.default.removeItem(atPath: outputPath)
    }
    guard makeVideoStickerFrameCache(path: path, size: size, outputPath: outputPath, isCancelled: isCancelled) else {
        return nil
    }
    return try? Data(contentsOf: URL(fileURLWithPath: outputPath))
}
