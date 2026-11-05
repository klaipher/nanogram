import Foundation
import Compression
import Display
import SwiftSignalKit
import UniversalMediaPlayer
import CoreMedia
import ManagedFile
import Accelerate
import TelegramCore
import WebPBinding
import VP9Hardware
import UIKit

private let sharedStoreQueue = Queue.concurrentDefaultQueue()

private let maximumFrameCount = 30 * 10

final class VideoStickerFrameSourceCache {
    private enum FrameRangeResult {
        case range(Range<Int>)
        case notFound
        case corruptedFile
    }
    
    private let queue: Queue
    private let storeQueue: Queue
    private let path: String
    private let file: ManagedFile
    private let width: Int
    private let height: Int
    
    public private(set) var frameRate: Int32 = 0
    public private(set) var frameCount: Int32 = 0
    
    private var isStoringFrames = Set<Int>()
    var storedFrames: Int {
        return self.isStoringFrames.count
    }
    
    private var scratchBuffer: Data
    private let decodedFrameLength: Int
    
    // 4: frames are LZ4 (3 was LZFSE).
    static let version: Int = 4
    
    static func path(pathPrefix: String, width: Int, height: Int, version: Int) -> String {
        return "\(pathPrefix)_\(width)x\(height)-v\(version).vstickerframecache"
    }
    
    init?(queue: Queue, pathPrefix: String, width: Int, height: Int) {
        self.queue = queue
        self.storeQueue = sharedStoreQueue
        
        self.width = width
        self.height = height
        
        self.path = VideoStickerFrameSourceCache.path(pathPrefix: pathPrefix, width: width, height: height, version: VideoStickerFrameSourceCache.version)
        var file = ManagedFile(queue: queue, path: self.path, mode: .readwrite)
        if let file = file {
            self.file = file
        } else {
            let _ = try? FileManager.default.removeItem(atPath: self.path)
            file = ManagedFile(queue: queue, path: self.path, mode: .readwrite)
            if let file = file {
                self.file = file
            } else {
                return nil
            }
        }
        
        self.scratchBuffer = Data(count: compression_decode_scratch_buffer_size(stickerFrameCompressionAlgorithm))
        
        let yuvaPixelsPerAlphaRow = (Int(width) + 1) & (~1)
        let yuvaLength = Int(width) * Int(height) * 2 + yuvaPixelsPerAlphaRow * Int(height) / 2
        self.decodedFrameLength = yuvaLength
        
        if self.initializeFrameTable() {
            // A new file replaces the previous version's, which nothing reads any more.
            unlink(VideoStickerFrameSourceCache.path(pathPrefix: pathPrefix, width: width, height: height, version: VideoStickerFrameSourceCache.version - 1))
        }
    }
    
    deinit {
        if self.frameCount == 0 {
            let _ = try? FileManager.default.removeItem(atPath: self.path)
        }
    }
    
    @discardableResult
    private func initializeFrameTable() -> Bool {
        var reset = true
        if let size = self.file.getSize(), size >= maximumFrameCount {
            if self.readFrameRate() {
                reset = false
            }
        }
        if reset {
            self.file.truncate(count: 0)
            var zero: Int32 = 0
            let _ = self.file.write(&zero, count: 4)
            let _ = self.file.write(&zero, count: 4)
            
            for _ in 0 ..< maximumFrameCount {
                let _ = self.file.write(&zero, count: 4)
                let _ = self.file.write(&zero, count: 4)
            }
        }
        return reset
    }
    
    private func readFrameRate() -> Bool {
        guard self.frameCount == 0 else {
            return true
        }
       
        let _ = self.file.seek(position: 0)
        var frameRate: Int32 = 0
        if self.file.read(&frameRate, 4) != 4 {
            return false
        }
        if frameRate < 0 {
            return false
        }
        if frameRate == 0 {
            return false
        }
        self.frameRate = frameRate
        
        let _ = self.file.seek(position: 4)
        
        var frameCount: Int32 = 0
        if self.file.read(&frameCount, 4) != 4 {
            return false
        }
        
        if frameCount < 0 {
            return false
        }
        if frameCount == 0 {
            return false
        }
        self.frameCount = frameCount
        
        return true
    }
    
    private func readFrameRange(index: Int) -> FrameRangeResult {
        if index < 0 || index >= maximumFrameCount {
            return .notFound
        }
        
        guard self.readFrameRate() else {
            return .notFound
        }
                
        if index >= self.frameCount {
            return .notFound
        }
        
        let _ = self.file.seek(position: Int64(8 + index * 4 * 2))
        var offset: Int32 = 0
        var length: Int32 = 0
        if self.file.read(&offset, 4) != 4 {
            return .corruptedFile
        }
        if self.file.read(&length, 4) != 4 {
            return .corruptedFile
        }
        if length == 0 {
            return .notFound
        }
        if length < 0 || offset < 0 {
            return .corruptedFile
        }
        if Int64(offset) + Int64(length) > 100 * 1024 * 1024 {
            return .corruptedFile
        }
        
        return .range(Int(offset) ..< Int(offset + length))
    }
    
    func storeFrameRateAndCount(frameRate: Int, frameCount: Int) {
        let _ = self.file.seek(position: 0)
        var frameRate = Int32(frameRate)
        let _ = self.file.write(&frameRate, count: 4)
       
        let _ = self.file.seek(position: 4)
        var frameCount = Int32(frameCount)
        let _ = self.file.write(&frameCount, count: 4)
    }
    
    func storeUncompressedRgbFrame(index: Int, rgbData: Data) {
        if index < 0 || index >= maximumFrameCount {
            return
        }
        if self.isStoringFrames.contains(index) {
            return
        }
        self.isStoringFrames.insert(index)
        
        let width = self.width
        let height = self.height
        
        let queue = self.queue
        self.storeQueue.async { [weak self] in
            let compressedData = compressFrame(width: width, height: height, rgbData: rgbData, unpremultiply: false)
            
            queue.async {
                guard let strongSelf = self else {
                    return
                }
                guard let currentSize = strongSelf.file.getSize() else {
                    return
                }
                guard let compressedData = compressedData else {
                    return
                }
                
                let _ = strongSelf.file.seek(position: Int64(8 + index * 4 * 2))
                var offset = Int32(currentSize)
                var length = Int32(compressedData.count)
                let _ = strongSelf.file.write(&offset, count: 4)
                let _ = strongSelf.file.write(&length, count: 4)
                let _ = strongSelf.file.seek(position: Int64(currentSize))
                compressedData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Void in
                    if let baseAddress = buffer.baseAddress {
                        let _ = strongSelf.file.write(baseAddress, count: Int(length))
                    }
                }
            }
        }
    }
    
    func readUncompressedYuvaFrame(index: Int) -> Data? {
        if index < 0 || index >= maximumFrameCount {
            return nil
        }
        let rangeResult = self.readFrameRange(index: index)
        
        switch rangeResult {
        case let .range(range):
            let _ = self.file.seek(position: Int64(range.lowerBound))
            let length = range.upperBound - range.lowerBound
            let compressedData = self.file.readData(count: length)
            if compressedData.count != length {
                return nil
            }
            
            // Straight into the frame's own buffer: copying a decoded frame cost a vm_copy per frame.
            let decodedFrameLength = self.decodedFrameLength
            return compressedData.withUnsafeBytes { buffer -> Data? in
                guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return nil
                }
                return self.scratchBuffer.withUnsafeMutableBytes { scratchBuffer -> Data? in
                    return decompressFrame(bytes: bytes, length: length, decodedLength: decodedFrameLength, scratch: scratchBuffer.baseAddress)
                }
            }
        case .notFound:
            return nil
        case .corruptedFile:
            self.file.truncate(count: 0)
            self.initializeFrameTable()
            
            return nil
        }
    }
}

private let useCache = true

public func makeVideoStickerDirectFrameSource(queue: Queue, path: String, hintVP9: Bool, width: Int, height: Int, cachePathPrefix: String?, unpremultiplyAlpha: Bool) -> AnimatedStickerFrameSource? {
    return VideoStickerDirectFrameSource(queue: queue, path: path, isVP9: hintVP9, width: width, height: height, cachePathPrefix: cachePathPrefix, unpremultiplyAlpha: unpremultiplyAlpha)
}

// Files opened by video sticker frame sources, for tests.
let videoStickerReaderOpenCount = Atomic<Int>(value: 0)

private func makeVideoStickerReader(path: String) -> FFMpegFileReader? {
    let _ = videoStickerReaderOpenCount.modify { $0 + 1 }
    return FFMpegFileReader(
        source: .file(path),
        passthroughDecoder: false,
        useHardwareAcceleration: false,
        selectedStream: .mediaType(.video),
        seek: nil,
        maxReadablePts: nil
    )
}

public final class VideoStickerDirectFrameSource: AnimatedStickerFrameSource {
    private let queue: Queue
    private let path: String
    private let width: Int
    private let height: Int
    private let cache: VideoStickerFrameSourceCache?
    private let image: UIImage?
    private let bytesPerRow: Int
    public var frameCount: Int
    public let frameRate: Int
    public var duration: Double
    fileprivate var currentFrame: Int
    
    private var source: FFMpegFileReader?
    // Set at the end of the stream; the reader is rewound when it is read from again.
    private var sourceNeedsRewind = false
    // Hardware VP9 decoding, when the device has it; the reader above stays for metadata and fallback.
    private var hardwareStream: VideoStickerHardwareStream?
    private lazy var hardwareConverter = VideoStickerHardwareFrameConverter()

    var usesHardwareDecoderForTesting: Bool {
        return self.hardwareStream != nil
    }
    
    public var frameIndex: Int {
        if self.frameCount == 0 {
            return 0
        } else {
            return self.currentFrame % self.frameCount
        }
    }
    
    public init?(queue: Queue, path: String, isVP9: Bool = true, width: Int, height: Int, cachePathPrefix: String?, unpremultiplyAlpha: Bool = true) {
        self.queue = queue
        self.path = path
        self.width = width
        self.height = height
        self.bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: Int(self.width))
        self.currentFrame = 0
  
        self.cache = cachePathPrefix.flatMap { cachePathPrefix in
            VideoStickerFrameSourceCache(queue: queue, pathPrefix: cachePathPrefix, width: width, height: height)
        }
        
        if useCache, let cache = self.cache, cache.frameCount > 0 {
            self.source = nil
            self.image = nil
            self.frameRate = Int(cache.frameRate)
            self.frameCount = Int(cache.frameCount)
            if self.frameRate > 0 {
                self.duration = Double(self.frameCount) / Double(self.frameRate)
            } else {
                self.duration = 0.0
            }
        } else if videoStickerFileIsWebP(path: path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let image = WebP.convert(fromWebP: data, fittingPixelSize: CGSize(width: 1024.0, height: 1024.0)) {
            self.source = nil
            self.image = image
            self.frameRate = 1
            self.frameCount = 1
            self.duration = 0.0
        } else {
            let source = makeVideoStickerReader(path: path)
            if let source {
                self.source = source
                self.frameRate = min(30, source.frameRate())
                self.duration = source.duration().seconds
                if isVP9 {
                    self.hardwareStream = makeVideoStickerHardwareStream(path)
                }
            } else {
                self.source = nil
                self.frameRate = 30
                self.duration = 0.0
            }
            self.image = nil
            self.frameCount = 0
        }
    }
    
    deinit {
        assert(self.queue.isCurrent())
    }
    
    public func takeFrame(draw: Bool) -> AnimatedStickerFrame? {
        let frameIndex: Int
        if self.frameCount > 0 {
            frameIndex = self.currentFrame % self.frameCount
        } else {
            frameIndex = self.currentFrame
        }

        self.currentFrame += 1
        if draw {
            if let image = self.image {
                guard let context = DrawingContext(size: CGSize(width: self.width, height: self.height), scale: 1.0, opaque: false, clear: true, bytesPerRow: self.bytesPerRow) else {
                    return nil
                }
                context.withFlippedContext { c in
                    c.draw(image.cgImage!, in: CGRect(origin: CGPoint(), size: context.size))
                }
                let frameData = Data(bytes: context.bytes, count: self.bytesPerRow * self.height)
                                
                return AnimatedStickerFrame(data: frameData, type: .argb, width: self.width, height: self.height, bytesPerRow: self.bytesPerRow, index: frameIndex, isLastFrame: frameIndex == self.frameCount - 1, totalFrames: self.frameCount, multiplyAlpha: true)
            } else if useCache, let cache = self.cache, let yuvData = cache.readUncompressedYuvaFrame(index: frameIndex) {
                return AnimatedStickerFrame(data: yuvData, type: .yuva, width: self.width, height: self.height, bytesPerRow: self.width * 2, index: frameIndex, isLastFrame: frameIndex == self.frameCount - 1, totalFrames: self.frameCount)
            } else {
                self.resumeHardwareDecodingIfSuspended()
                if let hardwareStream = self.hardwareStream {
                    switch self.takeHardwareFrame(hardwareStream, frameIndex: frameIndex) {
                    case let .frame(frame):
                        return frame
                    case .endOfStream:
                        let frame = self.endOfStream(frameIndex: frameIndex)
                        self.releaseHardwareDecodingIfCacheIsComplete()
                        return frame
                    case .failed:
                        self.fallBackToSoftwareDecoding(hardwareStream)
                        return self.takeSoftwareFrame(frameIndex: frameIndex)
                    }
                } else {
                    return self.takeSoftwareFrame(frameIndex: frameIndex)
                }
            }
        } else {
            return nil
        }
    }

    private func takeSoftwareFrame(frameIndex: Int) -> AnimatedStickerFrame? {
        guard let source = self.rewoundSource() else {
            return nil
        }
        var frameAndLoop = source.readFrame(argb: true)
        if case .endOfStream = frameAndLoop, self.sourceWasJustRewound, self.frameCount > 0 {
            // The seek did not work: read from a new reader, as before.
            self.sourceWasJustRewound = false
            if let newSource = makeVideoStickerReader(path: self.path) {
                self.source = newSource
                frameAndLoop = newSource.readFrame(argb: true)
            }
        }
        self.sourceWasJustRewound = false
        switch frameAndLoop {
        case let .frame(frame):
            guard let imageBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
                return nil
            }
            CVPixelBufferLockBaseAddress(imageBuffer, CVPixelBufferLockFlags(rawValue: 0))
            defer {
                CVPixelBufferUnlockBaseAddress(imageBuffer, CVPixelBufferLockFlags(rawValue: 0))
            }
            guard let srcData = CVPixelBufferGetBaseAddress(imageBuffer) else {
                return nil
            }
            return self.makeArgbFrame(source: UnsafeRawPointer(srcData), width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer), bytesPerRow: CVPixelBufferGetBytesPerRow(imageBuffer), frameIndex: frameIndex)
        case .endOfStream:
            return self.endOfStream(frameIndex: frameIndex)
        case .waitingForMoreData, .error:
            return nil
        }
    }

    // Scales a decoded BGRA frame to the sticker size and stores it in the frame cache.
    private func makeArgbFrame(source: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, frameIndex: Int) -> AnimatedStickerFrame {
        var frameData = Data(count: self.bytesPerRow * self.height)
        frameData.withUnsafeMutableBytes { buffer -> Void in
            guard let bytes = buffer.baseAddress else {
                return
            }
            var sourceBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
            var destBuffer = vImage_Buffer(data: bytes, height: vImagePixelCount(self.height), width: vImagePixelCount(self.width), rowBytes: self.bytesPerRow)
            let _ = vImageScale_ARGB8888(&sourceBuffer, &destBuffer, nil, vImage_Flags(kvImageDoNotTile))
        }

        self.cache?.storeUncompressedRgbFrame(index: frameIndex, rgbData: frameData)

        return AnimatedStickerFrame(data: frameData, type: .argb, width: self.width, height: self.height, bytesPerRow: self.bytesPerRow, index: frameIndex, isLastFrame: frameIndex == self.frameCount - 1, totalFrames: self.frameCount, multiplyAlpha: true)
    }

    private func endOfStream(frameIndex: Int) -> AnimatedStickerFrame? {
        if self.frameCount == 0 {
            if let cache = self.cache {
                if cache.storedFrames == frameIndex {
                    self.frameCount = frameIndex
                    cache.storeFrameRateAndCount(frameRate: self.frameRate, frameCount: self.frameCount)
                } else {
                    Logger.shared.log("VideoSticker", "Missed a frame? \(frameIndex) \(cache.storedFrames)")
                }
            } else {
                self.frameCount = frameIndex
            }
        }
        self.currentFrame = 0
        self.sourceNeedsRewind = true

        if let cache = self.cache {
            if let yuvData = cache.readUncompressedYuvaFrame(index: self.currentFrame) {
                return AnimatedStickerFrame(data: yuvData, type: .yuva, width: self.width, height: self.height, bytesPerRow: self.width * 2, index: frameIndex, isLastFrame: frameIndex == self.frameCount - 1, totalFrames: self.frameCount)
            }
        }

        return nil
    }

    private enum HardwareFrameResult {
        case frame(AnimatedStickerFrame)
        case endOfStream
        case failed
    }

    private func takeHardwareFrame(_ stream: VideoStickerHardwareStream, frameIndex: Int) -> HardwareFrameResult {
        if stream.nextFrameIndex >= stream.frames.count {
            stream.nextFrameIndex = 0
            stream.decoder.reset()
            return .endOfStream
        }
        guard let decoded = stream.decoder.decode(stream.frames[stream.nextFrameIndex]) else {
            return .failed
        }
        var result: AnimatedStickerFrame?
        let converted = self.hardwareConverter.convert(decoded) { source, width, height, bytesPerRow in
            result = self.makeArgbFrame(source: source, width: width, height: height, bytesPerRow: bytesPerRow, frameIndex: frameIndex)
        }
        guard converted, let result else {
            return .failed
        }
        stream.nextFrameIndex += 1
        return .frame(result)
    }

    // The frame the hardware decoder had reached when `suspendHardwareDecoding` released it.
    private var suspendedHardwarePosition: Int?

    // Gives the hardware decoder sessions back while the sticker is not shown: they are a small, shared resource
    // (a sticker with alpha takes two of eight), and a hidden sticker that keeps them leaves another one on libvpx.
    // The next frame that is taken sets a decoder up again at the same frame. Call it on the frame source's queue.
    func suspendHardwareDecoding() {
        guard let stream = self.hardwareStream else {
            return
        }
        self.suspendedHardwarePosition = stream.nextFrameIndex
        stream.decoder.invalidate()
        self.hardwareStream = nil
    }

    // At the end of the first loop the frame cache holds every frame, and all later frames come from it: the
    // decoder would only keep its sessions from other stickers. If the cache cannot give a frame later, a decoder
    // is set up again from the first frame, where this one would have restarted.
    private func releaseHardwareDecodingIfCacheIsComplete() {
        guard self.cache != nil, self.frameCount > 0, let stream = self.hardwareStream else {
            return
        }
        stream.decoder.invalidate()
        self.hardwareStream = nil
        self.suspendedHardwarePosition = 0
    }

    private func resumeHardwareDecodingIfSuspended() {
        guard let position = self.suspendedHardwarePosition else {
            return
        }
        self.suspendedHardwarePosition = nil
        // A new decoder can only start from the first frame (a key frame): the frames before the position are
        // decoded and dropped. At the end of the stream the next frame starts over anyway.
        guard let stream = makeVideoStickerHardwareStream(self.path) else {
            self.continueWithSoftwareDecoding(from: position)
            return
        }
        if position < stream.frames.count {
            for index in 0 ..< position {
                if stream.decoder.decode(stream.frames[index]) == nil {
                    stream.decoder.invalidate()
                    self.continueWithSoftwareDecoding(from: position)
                    return
                }
            }
        }
        stream.nextFrameIndex = position
        self.hardwareStream = stream
    }

    // Continues with libvpx from the frame the hardware decoder could not decode.
    private func fallBackToSoftwareDecoding(_ stream: VideoStickerHardwareStream) {
        let position = stream.nextFrameIndex
        stream.decoder.invalidate()
        self.hardwareStream = nil
        Logger.shared.log("VideoSticker", "Hardware VP9 decoding stopped at frame \(position), continuing with libvpx")
        self.continueWithSoftwareDecoding(from: position)
    }

    private func continueWithSoftwareDecoding(from position: Int) {
        guard let source = self.rewoundSource() else {
            return
        }
        self.sourceWasJustRewound = false
        for _ in 0 ..< position {
            guard case .frame = source.readFrame(argb: true) else {
                break
            }
        }
    }

    private var sourceWasJustRewound = false

    private func rewoundSource() -> FFMpegFileReader? {
        guard let source = self.source else {
            return nil
        }
        if !self.sourceNeedsRewind {
            return source
        }
        self.sourceNeedsRewind = false
        if source.rewind() {
            self.sourceWasJustRewound = true
            return source
        }
        self.source = makeVideoStickerReader(path: self.path)
        return self.source
    }

    public func skipToEnd() {
        self.currentFrame = self.frameCount - 1
    }

    public func skipToFrameIndex(_ index: Int) {
        self.currentFrame = index
    }
}


/// Whether the file starts with the WebP signature (`RIFF`, four size bytes, `WEBP`). Only 12 bytes are read, so a
/// WebM video sticker is not read into memory in full just to find out that it is not an image.
func videoStickerFileIsWebP(path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else {
        return false
    }
    defer {
        try? handle.close()
    }
    guard let header = try? handle.read(upToCount: 12) else {
        return false
    }
    return videoStickerDataIsWebP(header)
}

func videoStickerDataIsWebP(_ header: Data) -> Bool {
    if header.count < 12 {
        return false
    }
    let bytes = [UInt8](header.prefix(12))
    return bytes[0 ..< 4].elementsEqual(Array("RIFF".utf8)) && bytes[8 ..< 12].elementsEqual(Array("WEBP".utf8))
}
