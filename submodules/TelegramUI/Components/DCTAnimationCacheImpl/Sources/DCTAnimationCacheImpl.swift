import Foundation
import UIKit
import SwiftSignalKit
import CryptoUtils
import ManagedFile
import DiskWriteAccounting
import Compression
import AnimationCache
import ImageDCT

// Format 6: raw int16 DCT coefficients in an LZFSE stream.
// Format 7: the same coefficients packed by sparseCoefficientsEncode, in an LZFSE stream.
// The coefficients are ~92% zeros, so packing first leaves LZFSE ~6x less input.
// Measured on real emoji and stickers: writing 1.9-2.3x faster, files 12% smaller,
// playback no slower. LZ4 instead of LZFSE wrote 3x faster but files were 33% larger
// than format 6. Older builds reject format 7 files and regenerate them.
// Format 8: the same coefficients, compressed in blocks of whole frames (at least 64 KB except the
// last), named by a codec byte after the version. These codecs have only a buffer API, hence the
// blocks; the reader keeps one decoded block. Formats 6 and 7 stay readable.
// The writer uses LZBITMAP. Measured on the repo fixtures against the format-7 LZFSE stream
// (fix-bench/media/dct/blocks.txt): LZBITMAP encodes 62-73% and decodes 58-74% faster for files
// 25-29% larger; LZMESH (iOS 27+) keeps the size but encodes only ~52% faster and decodes no
// faster, and decoding runs for every displayed frame. LZMESH files are still read on iOS 27+.
private let currentFormatVersion: UInt32 = 8

// Tests write format 6 through this to compare the two.
var dctAnimationCacheWriterFormatVersion: UInt32 = currentFormatVersion

private let algorithm: compression_algorithm = COMPRESSION_LZFSE

// The block codec of a format 8 file, stored in the byte after the version.
enum DCTAnimationCacheCodec: UInt8 {
    case lzbitmap = 1
    case lzmesh = 2

    var algorithm: compression_algorithm {
        switch self {
        case .lzbitmap:
            return COMPRESSION_LZBITMAP
        case .lzmesh:
            return COMPRESSION_LZMESH
        }
    }
}

// Tests write a given codec through this.
var dctAnimationCacheWriterCodecOverride: DCTAnimationCacheCodec?

private func dctAnimationCacheWriterCodec() -> DCTAnimationCacheCodec {
    return dctAnimationCacheWriterCodecOverride ?? .lzbitmap
}

// Whether this OS can decode files written with `codec`.
private func isDecodable(_ codec: DCTAnimationCacheCodec) -> Bool {
    switch codec {
    case .lzbitmap:
        return true
    case .lzmesh:
        if #available(iOS 27.0, *) {
            return true
        } else {
            return false
        }
    }
}

// The frame payload stream of a cache file, written frame by frame.
private protocol FrameStreamWriter: AnyObject {
    func write(bytes: UnsafePointer<UInt8>, count: Int) throws
    // Called after each frame's bytes; a block ends only here.
    func endFrame() throws
    func flush() throws
}

private extension FrameStreamWriter {
    func writeUInt32(_ value: UInt32) throws {
        var value: UInt32 = value
        try withUnsafePointer(to: &value) { pointer in
            try pointer.withMemoryRebound(to: UInt8.self, capacity: 4) { bytes in
                try self.write(bytes: bytes, count: 4)
            }
        }
    }
}

private protocol FrameStreamReader: AnyObject {
    func read(bytes: UnsafeMutablePointer<UInt8>, count: Int) throws
}

private extension FrameStreamReader {
    func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        try withUnsafeMutablePointer(to: &value) { pointer in
            try pointer.withMemoryRebound(to: UInt8.self, capacity: 4) { bytes in
                try self.read(bytes: bytes, count: 4)
            }
        }
        return value
    }
}

private func alignUp(size: Int, align: Int) -> Int {
    precondition(((align - 1) & align) == 0, "Align must be a power of two")

    let alignmentMask = align - 1
    return (size + alignmentMask) & ~alignmentMask
}

private func fileSize(_ path: String, useTotalFileAllocatedSize: Bool = false) -> Int64? {
    if useTotalFileAllocatedSize {
        let url = URL(fileURLWithPath: path)
        if let values = (try? url.resourceValues(forKeys: Set([.isRegularFileKey, .fileAllocatedSizeKey]))) {
            if values.isRegularFile ?? false {
                if let fileSize = values.fileAllocatedSize {
                    return Int64(fileSize)
                }
            }
        }
    }
    
    var value = stat()
    if stat(path, &value) == 0 {
        return value.st_size
    } else {
        return nil
    }
}

// The media cache cleanup removes files by modification date, and a hit never writes the
// file, so items in daily use were deleted and converted again. A hit moves the date
// forward, at most once an hour per file. Returns false if the file does not exist.
// The shortest "keep media" setting is one day and the cleanup runs at launch, so a
// once-a-day refresh would almost never land before the file was already past the limit.
private let modificationDateRefreshInterval: Int = 60 * 60

private func cachedItemExists(path: String) -> Bool {
    var value = stat()
    if stat(path, &value) != 0 {
        return false
    }
    if Int(Date().timeIntervalSince1970) - Int(value.st_mtimespec.tv_sec) > modificationDateRefreshInterval {
        utime(path, nil)
    }
    return true
}

private func md5Hash(_ string: String) -> String {
    let hashData = string.data(using: .utf8)!.withUnsafeBytes { bytes -> Data in
        return CryptoMD5(bytes.baseAddress!, Int32(bytes.count))
    }
    return hashData.withUnsafeBytes { bytes -> String in
        let uintBytes = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
        return String(format: "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x", uintBytes[0], uintBytes[1], uintBytes[2], uintBytes[3], uintBytes[4], uintBytes[5], uintBytes[6], uintBytes[7], uintBytes[8], uintBytes[9], uintBytes[10], uintBytes[11], uintBytes[12], uintBytes[13], uintBytes[14], uintBytes[15])
    }
}

private func itemSubpath(hashString: String, width: Int, height: Int) -> (directory: String, fileName: String) {
    assert(hashString.count == 32)
    var directory = ""
    
    for i in 0 ..< 1 {
        if !directory.isEmpty {
            directory.append("/")
        }
        directory.append(String(hashString[hashString.index(hashString.startIndex, offsetBy: i * 2) ..< hashString.index(hashString.startIndex, offsetBy: (i + 1) * 2)]))
    }
    
    return (directory, "\(hashString)_\(width)x\(height)")
}

private func roundUp(_ numToRound: Int, multiple: Int) -> Int {
    if multiple == 0 {
        return numToRound
    }
    
    let remainder = numToRound % multiple
    if remainder == 0 {
        return numToRound;
    }
    
    return numToRound + multiple - remainder
}

private func compressData(data: Data, addSizeHeader: Bool = false) -> Data? {
    let scratchData = malloc(compression_encode_scratch_buffer_size(algorithm))!
    defer {
        free(scratchData)
    }
    
    let headerSize = addSizeHeader ? 4 : 0
    var compressedData = Data(count: headerSize + data.count + 16 * 1024)
    let resultSize = compressedData.withUnsafeMutableBytes { buffer -> Int in
        guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }
        
        if addSizeHeader {
            var decompressedSize: UInt32 = UInt32(data.count)
            memcpy(bytes, &decompressedSize, 4)
        }
        
        return data.withUnsafeBytes { sourceBuffer -> Int in
            return compression_encode_buffer(bytes.advanced(by: headerSize), buffer.count - headerSize, sourceBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), sourceBuffer.count, scratchData, algorithm)
        }
    }
    
    if resultSize <= 0 {
        return nil
    }
    compressedData.count = headerSize + resultSize
    return compressedData
}

private func decompressData(data: Data, range: Range<Int>, decompressedSize: Int) -> Data? {
    let scratchData = malloc(compression_decode_scratch_buffer_size(algorithm))!
    defer {
        free(scratchData)
    }
    
    var decompressedFrameData = Data(count: decompressedSize)
    let resultSize = decompressedFrameData.withUnsafeMutableBytes { buffer -> Int in
        guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }
        return data.withUnsafeBytes { sourceBuffer -> Int in
            return compression_decode_buffer(bytes, buffer.count, sourceBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: range.lowerBound), range.upperBound - range.lowerBound, scratchData, algorithm)
        }
    }
    
    if resultSize <= 0 {
        return nil
    }
    if decompressedFrameData.count != resultSize {
        decompressedFrameData.count = resultSize
    }
    return decompressedFrameData
}

private final class AnimationCacheItemWriterImpl: AnimationCacheItemWriter {
    enum WriteError: Error {
        case generic
    }
    
    struct CompressedResult {
        var animationPath: String
    }
    
    private struct FrameMetadata {
        var duration: Double
    }
    
    var queue: Queue {
        return self.innerQueue
    }
    let innerQueue: Queue
    private var isCancelledValue: Bool = false
    // A failed writer drops every further frame, so producers can stop decoding them.
    var isCancelled: Bool {
        get {
            return self.isCancelledValue || self.isFailed
        } set {
            self.isCancelledValue = newValue
        }
    }
    
    private let compressedPath: String
    private var file: ManagedFile?
    private var compressedWriter: FrameStreamWriter?
    private let codec: DCTAnimationCacheCodec
    private let completion: (CompressedResult?) -> Void
    
    
    private var currentSurface: ImageARGB?
    private var currentYUVASurface: ImageYUVA420?
    private var currentFrameFloat: FloatCoefficientsYUVA420?
    private var previousFrameCoefficients: DctCoefficientsYUVA420?
    private var deltaFrameFloat: FloatCoefficientsYUVA420?
    private var previousYUVASurface: ImageYUVA420?
    private var currentDctData: DctData?
    private var differenceCoefficients: DctCoefficientsYUVA420?
    private var currentDctCoefficients: DctCoefficientsYUVA420?
    private var contentLengthOffset: Int?
    private var isFailed: Bool = false
    private var isFinished: Bool = false
    
    private var frames: [FrameMetadata] = []
    private let formatVersion: UInt32
    private var sparseBuffer: UnsafeMutablePointer<UInt8>?
    private var sparseBufferCapacity: Int = 0
    
    private let dctQualityLuma: Int
    private let dctQualityChroma: Int
    private let dctQualityDelta: Int
    
    private let lock = Lock()
    
    init?(queue: Queue, allocateTempFile: @escaping () -> String, completion: @escaping (CompressedResult?) -> Void) {
        self.dctQualityLuma = 70
        self.dctQualityChroma = 88
        self.dctQualityDelta = 22
        
        self.innerQueue = queue
        self.formatVersion = dctAnimationCacheWriterFormatVersion
        self.codec = dctAnimationCacheWriterCodec()
        self.compressedPath = allocateTempFile()
        
        guard let file = ManagedFile(queue: nil, path: self.compressedPath, mode: .readwrite) else {
            return nil
        }
        self.file = file
        if self.formatVersion >= 8 {
            self.compressedWriter = BlockCompressedFileWriter(file: file, codec: self.codec)
        } else {
            self.compressedWriter = CompressedFileWriter(file: file)
        }
        self.completion = completion
    }
    
    deinit {
        self.sparseBuffer?.deallocate()
    }
    
    func add(with drawingBlock: (AnimationCacheItemDrawingSurface) -> Double?, proposedWidth: Int, proposedHeight: Int, insertKeyframe: Bool) {
        do {
            try self.lock.throwingLocked {
                let width = roundUp(proposedWidth, multiple: 16)
                let height = roundUp(proposedHeight, multiple: 16)
                
                let surface: ImageARGB
                if let current = self.currentSurface {
                    if current.argbPlane.width == width && current.argbPlane.height == height {
                        surface = current
                        surface.argbPlane.data.withUnsafeMutableBytes { bytes -> Void in
                            memset(bytes.baseAddress!, 0, bytes.count)
                        }
                    } else {
                        self.isFailed = true
                        return
                    }
                } else {
                    surface = ImageARGB(width: width, height: height, rowAlignment: 32)
                    self.currentSurface = surface
                }
                
                let duration = surface.argbPlane.data.withUnsafeMutableBytes { bytes -> Double? in
                    return drawingBlock(AnimationCacheItemDrawingSurface(
                        argb: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        width: width,
                        height: height,
                        bytesPerRow: surface.argbPlane.bytesPerRow,
                        length: bytes.count
                    ))
                }
                
                guard let duration = duration else {
                    return
                }
                
                try addInternal(with: { yuvaSurface in
                    surface.toYUVA420(target: yuvaSurface)
                    
                    return duration
                }, width: width, height: height, insertKeyframe: insertKeyframe)
            }
        } catch {
        }
    }
    
    func addYUV(with drawingBlock: (ImageYUVA420) -> Double?, proposedWidth: Int, proposedHeight: Int, insertKeyframe: Bool) throws {
        let width = roundUp(proposedWidth, multiple: 16)
        let height = roundUp(proposedHeight, multiple: 16)
        
        do {
            try self.lock.throwingLocked {
                try addInternal(with: { yuvaSurface in
                    return drawingBlock(yuvaSurface)
                }, width: width, height: height, insertKeyframe: insertKeyframe)
            }
        } catch {
        }
    }
    
    func addInternal(with drawingBlock: (ImageYUVA420) -> Double?, width: Int, height: Int, insertKeyframe: Bool) throws {
        if width == 0 || height == 0 {
            self.isFailed = true
            throw WriteError.generic
        }
        if self.isFailed || self.isFinished {
            throw WriteError.generic
        }
        
        guard !self.isFailed, !self.isFinished, let file = self.file, let compressedWriter = self.compressedWriter else {
            throw WriteError.generic
        }
        
        var isFirstFrame = false
        
        let yuvaSurface: ImageYUVA420
        if let current = self.currentYUVASurface {
            if current.yPlane.width == width && current.yPlane.height == height {
                yuvaSurface = current
            } else {
                self.isFailed = true
                throw WriteError.generic
            }
        } else {
            isFirstFrame = true
            
            yuvaSurface = ImageYUVA420(width: width, height: height, rowAlignment: nil)
            self.currentYUVASurface = yuvaSurface
        }
        
        let currentFrameFloat: FloatCoefficientsYUVA420
        if let current = self.currentFrameFloat {
            if current.yPlane.width == width && current.yPlane.height == height {
                currentFrameFloat = current
            } else {
                self.isFailed = true
                throw WriteError.generic
            }
        } else {
            currentFrameFloat = FloatCoefficientsYUVA420(width: width, height: height)
            self.currentFrameFloat = currentFrameFloat
        }
        
        let previousFrameCoefficients: DctCoefficientsYUVA420
        if let current = self.previousFrameCoefficients {
            if current.yPlane.width == width && current.yPlane.height == height {
                previousFrameCoefficients = current
            } else {
                self.isFailed = true
                throw WriteError.generic
            }
        } else {
            previousFrameCoefficients = DctCoefficientsYUVA420(width: width, height: height)
            self.previousFrameCoefficients = previousFrameCoefficients
        }
        
        let deltaFrameFloat: FloatCoefficientsYUVA420
        if let current = self.deltaFrameFloat {
            if current.yPlane.width == width && current.yPlane.height == height {
                deltaFrameFloat = current
            } else {
                self.isFailed = true
                throw WriteError.generic
            }
        } else {
            deltaFrameFloat = FloatCoefficientsYUVA420(width: width, height: height)
            self.deltaFrameFloat = deltaFrameFloat
        }
        
        let dctData: DctData
        if let current = self.currentDctData {
            dctData = current
        } else {
            dctData = DctData(generatingTablesAtQualityLuma: self.dctQualityLuma, chroma: self.dctQualityChroma, delta: self.dctQualityDelta)
            self.currentDctData = dctData
        }
        
        let duration = drawingBlock(yuvaSurface)
        
        guard let duration = duration else {
            return
        }
        
        let dctCoefficients: DctCoefficientsYUVA420
        if let current = self.currentDctCoefficients {
            if current.yPlane.width == width && current.yPlane.height == height {
                dctCoefficients = current
            } else {
                self.isFailed = true
                throw WriteError.generic
            }
        } else {
            dctCoefficients = DctCoefficientsYUVA420(width: width, height: height)
            self.currentDctCoefficients = dctCoefficients
        }
        
        let differenceCoefficients: DctCoefficientsYUVA420
        if let current = self.differenceCoefficients {
            if current.yPlane.width == width && current.yPlane.height == height {
                differenceCoefficients = current
            } else {
                self.isFailed = true
                throw WriteError.generic
            }
        } else {
            differenceCoefficients = DctCoefficientsYUVA420(width: width, height: height)
            self.differenceCoefficients = differenceCoefficients
        }
        
        #if !arch(arm64)
        var insertKeyframe = insertKeyframe
        insertKeyframe = true
        #endif
        
        let previousYUVASurface: ImageYUVA420
        if let current = self.previousYUVASurface {
            previousYUVASurface = current
        } else {
            previousYUVASurface = ImageYUVA420(width: dctCoefficients.yPlane.width, height: dctCoefficients.yPlane.height, rowAlignment: nil)
            self.previousYUVASurface = previousYUVASurface
        }
        
        let isKeyframe: Bool
        if !isFirstFrame && !insertKeyframe {
            isKeyframe = false
            
            //previous + delta = current
            //delta = current - previous
            yuvaSurface.toCoefficients(target: differenceCoefficients)
            differenceCoefficients.subtract(other: previousFrameCoefficients)
            differenceCoefficients.dct4x4(dctData: dctData, target: dctCoefficients)
            
            //previous + delta = current
            dctCoefficients.idct4x4Add(dctData: dctData, target: previousFrameCoefficients)
            //previousFrameCoefficients.add(other: differenceCoefficients)
        } else {
            isKeyframe = true
            
            yuvaSurface.dct8x8(dctData: dctData, target: dctCoefficients)
            
            dctCoefficients.idct8x8(dctData: dctData, target: yuvaSurface)
            yuvaSurface.toCoefficients(target: previousFrameCoefficients)
        }
        
        if isFirstFrame {
            // One write for the whole header.
            var header = Data()
            writeUInt32(data: &header, value: self.formatVersion)
            if self.formatVersion >= 8 {
                header.append(self.codec.rawValue)
            }
            
            writeUInt32(data: &header, value: UInt32(dctCoefficients.yPlane.width))
            writeUInt32(data: &header, value: UInt32(dctCoefficients.yPlane.height))
            
            for table in [dctData.lumaTable.serializedData(), dctData.chromaTable.serializedData(), dctData.deltaTable.serializedData()] {
                writeUInt32(data: &header, value: UInt32(table.count))
                header.append(table)
            }
        
            self.contentLengthOffset = Int(file.position()) + header.count
            writeUInt32(data: &header, value: 0)
            let _ = file.write(header)
        }
        
        do {
            let frameLength = dctCoefficients.yPlane.data.count + dctCoefficients.uPlane.data.count + dctCoefficients.vPlane.data.count + dctCoefficients.aPlane.data.count
            try compressedWriter.writeUInt32(UInt32(frameLength))
            
            try compressedWriter.writeUInt32(isKeyframe ? 1 : 0)
            
            for i in 0 ..< 4 {
                let dctPlane: DctCoefficientPlane
                switch i {
                case 0:
                    dctPlane = dctCoefficients.yPlane
                case 1:
                    dctPlane = dctCoefficients.uPlane
                case 2:
                    dctPlane = dctCoefficients.vPlane
                case 3:
                    dctPlane = dctCoefficients.aPlane
                default:
                    preconditionFailure()
                }
                
                try compressedWriter.writeUInt32(UInt32(dctPlane.data.count))
                
                if self.formatVersion < 7 {
                    try dctPlane.data.withUnsafeBytes { bytes in
                        try compressedWriter.write(bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count)
                    }
                    continue
                }
                
                let coefficientCount = dctPlane.data.count / 2
                let maxEncodedLength = sparseCoefficientsMaxEncodedLength(coefficientCount)
                if self.sparseBufferCapacity < maxEncodedLength {
                    self.sparseBuffer?.deallocate()
                    self.sparseBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxEncodedLength)
                    self.sparseBufferCapacity = maxEncodedLength
                }
                let sparseBuffer = self.sparseBuffer!
                let encodedLength = dctPlane.data.withUnsafeBytes { bytes -> Int in
                    return sparseCoefficientsEncode(bytes.baseAddress!.assumingMemoryBound(to: Int16.self), coefficientCount, sparseBuffer)
                }
                try compressedWriter.writeUInt32(UInt32(encodedLength))
                try compressedWriter.write(bytes: sparseBuffer, count: encodedLength)
            }
            try compressedWriter.endFrame()
            
            self.frames.append(FrameMetadata(duration: duration))
        } catch {
            self.isFailed = true
            throw WriteError.generic
        }
    }
    
    func finish() {
        do {
            let result = try self.finishInternal()
            self.completion(result)
        } catch {
        }
    }
     
    func finishInternal() throws -> CompressedResult? {
        var shouldComplete = false
        self.lock.locked {
            if !self.isFinished {
                self.isFinished = true
                shouldComplete = true
                
                // The subscribers are gone: this partial item is dropped, not finished, and its temporary file is removed
                // below (it was left behind before).
                if self.isCancelledValue {
                    self.isFailed = true
                    return
                }
                
                guard let contentLengthOffset = self.contentLengthOffset, let file = self.file, let compressedWriter = self.compressedWriter else {
                    self.isFailed = true
                    return
                }
                assert(contentLengthOffset >= 0)
                
                do {
                    try compressedWriter.flush()
                
                    let metadataPosition = file.position()
                    let contentLength = Int(metadataPosition) - contentLengthOffset - 4
                    let _ = file.seek(position: Int64(contentLengthOffset))
                    file.write(UInt32(contentLength))
                    
                    let _ = file.seek(position: metadataPosition)
                    // One write for the duration table.
                    var table = Data(capacity: 4 + self.frames.count * 4)
                    writeUInt32(data: &table, value: UInt32(self.frames.count))
                    for frame in self.frames {
                        writeFloat32(data: &table, value: Float32(frame.duration))
                    }
                    let _ = file.write(table)
                    
                    if !self.isFailed {
                        self.compressedWriter = nil
                        self.file = nil
                        
                        file._unsafeClose()
                    }
                } catch {
                    self.isFailed = true
                }
            }
        }
        
        if shouldComplete {
            if !self.isFailed {
                return CompressedResult(animationPath: self.compressedPath)
            } else {
                let _ = try? FileManager.default.removeItem(atPath: self.compressedPath)
                return nil
            }
        } else {
           return nil
        }
    }
}

/// What the animation cache holds in memory, for the memory log: opened items (each keeps its whole compressed file
/// as `Data` and a decoded frame) and the bytes of those files. Readable from any thread.
public enum DCTAnimationCacheDiagnostics {
    private static let state = Atomic<(items: Int, bytes: Int)>(value: (0, 0))

    public static var openItems: (items: Int, bytes: Int) {
        return state.with({ $0 })
    }

    fileprivate static func opened(bytes: Int) {
        let _ = state.modify({ ($0.items + 1, $0.bytes + bytes) })
    }

    fileprivate static func closed(bytes: Int) {
        let _ = state.modify({ ($0.items - 1, $0.bytes - bytes) })
    }
}

private final class AnimationCacheItemAccessor {
    private enum ReadError: Error {
        case generic
    }
    
    final class CurrentFrame {
        let index: Int
        var remainingDuration: Double
        let duration: Double
        let yuva: ImageYUVA420
        
        init(index: Int, duration: Double, yuva: ImageYUVA420) {
            self.index = index
            self.duration = duration
            self.remainingDuration = duration
            self.yuva = yuva
        }
    }
    
    struct FrameInfo {
        let duration: Double
    }
    
    private let data: Data
    private let formatVersion: UInt32
    private let codec: DCTAnimationCacheCodec?
    private var compressedDataReader: FrameStreamReader?
    private var sparseBuffer: UnsafeMutablePointer<UInt8>?
    private var sparseBufferCapacity: Int = 0
    private let range: Range<Int>
    private let frameMapping: [Int: FrameInfo]
    private let width: Int
    private let height: Int
    private let durationMapping: [Double]
    
    private var currentFrame: CurrentFrame?
    
    private var currentYUVASurface: ImageYUVA420?
    private var currentCoefficients: DctCoefficientsYUVA420?
    private let currentDctData: DctData
    private var sharedDctCoefficients: DctCoefficientsYUVA420?
    private var deltaCoefficients: DctCoefficientsYUVA420?
    
    init(data: Data, formatVersion: UInt32, codec: DCTAnimationCacheCodec?, range: Range<Int>, frameMapping: [FrameInfo], width: Int, height: Int, dctData: DctData) {
        self.data = data
        self.formatVersion = formatVersion
        self.codec = codec
        self.range = range
        self.width = width
        self.height = height
        
        var resultFrameMapping: [Int: FrameInfo] = [:]
        var durationMapping: [Double] = []
        
        for i in 0 ..< frameMapping.count {
            let frame = frameMapping[i]
            resultFrameMapping[i] = frame
            durationMapping.append(frame.duration)
        }
        
        self.frameMapping = resultFrameMapping
        self.durationMapping = durationMapping
        
        self.currentDctData = dctData
        DCTAnimationCacheDiagnostics.opened(bytes: data.count)
    }
    
    deinit {
        DCTAnimationCacheDiagnostics.closed(bytes: self.data.count)
        self.sparseBuffer?.deallocate()
    }
    
    private func loadNextFrame() -> Bool {
        var didLoop = false
        let index: Int
        if let currentFrame = self.currentFrame {
            if currentFrame.index + 1 >= self.durationMapping.count {
                index = 0
                self.compressedDataReader = nil
                didLoop = true
            } else {
                index = currentFrame.index + 1
            }
        } else {
            index = 0
            self.compressedDataReader = nil
        }
        
        if self.compressedDataReader == nil {
            if let codec = self.codec {
                self.compressedDataReader = BlockDecompressedData(compressedData: self.data, dataRange: self.range, codec: codec)
            } else {
                self.compressedDataReader = DecompressedData(compressedData: self.data, dataRange: self.range)
            }
        }
        
        guard let compressedDataReader = self.compressedDataReader else {
            self.currentFrame = nil
            return didLoop
        }
        
        do {
            let frameLength = Int(try compressedDataReader.readUInt32())
            
            let frameType = Int(try compressedDataReader.readUInt32())
            
            let dctCoefficients: DctCoefficientsYUVA420
            // Every plane is fully overwritten below, so one buffer serves all frames.
            if let sharedDctCoefficients = self.sharedDctCoefficients, sharedDctCoefficients.yPlane.width == self.width, sharedDctCoefficients.yPlane.height == self.height {
                dctCoefficients = sharedDctCoefficients
            } else {
                dctCoefficients = DctCoefficientsYUVA420(width: self.width, height: self.height)
                self.sharedDctCoefficients = dctCoefficients
            }
            
            var frameOffset = 0
            for i in 0 ..< 4 {
                let planeLength = Int(try compressedDataReader.readUInt32())
                if planeLength < 0 || planeLength > 20 * 1024 * 1024 {
                    throw ReadError.generic
                }
                
                let plane: DctCoefficientPlane
                switch i {
                case 0:
                    plane = dctCoefficients.yPlane
                case 1:
                    plane = dctCoefficients.uPlane
                case 2:
                    plane = dctCoefficients.vPlane
                case 3:
                    plane = dctCoefficients.aPlane
                default:
                    throw ReadError.generic
                }
                
                if planeLength != plane.data.count {
                    throw ReadError.generic
                }
                
                if frameOffset + plane.data.count > frameLength {
                    throw ReadError.generic
                }
                
                if self.formatVersion >= 7 {
                    let coefficientCount = plane.data.count / 2
                    let encodedLength = Int(try compressedDataReader.readUInt32())
                    if encodedLength > sparseCoefficientsMaxEncodedLength(coefficientCount) {
                        throw ReadError.generic
                    }
                    // A first plane with encodedLength 0 would otherwise leave the buffer nil.
                    if self.sparseBuffer == nil || self.sparseBufferCapacity < encodedLength {
                        self.sparseBuffer?.deallocate()
                        self.sparseBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(encodedLength, 1))
                        self.sparseBufferCapacity = max(encodedLength, 1)
                    }
                    let sparseBuffer = self.sparseBuffer!
                    if encodedLength != 0 {
                        try compressedDataReader.read(bytes: sparseBuffer, count: encodedLength)
                    }
                    let decoded = plane.data.withUnsafeMutableBytes { bytes -> Bool in
                        return sparseCoefficientsDecode(sparseBuffer, encodedLength, bytes.baseAddress!.assumingMemoryBound(to: Int16.self), coefficientCount)
                    }
                    if !decoded {
                        throw ReadError.generic
                    }
                } else {
                    try plane.data.withUnsafeMutableBytes { bytes in
                        try compressedDataReader.read(bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytes.count)
                    }
                }
                frameOffset += plane.data.count
            }
            
            let yuvaSurface: ImageYUVA420
            if let currentYUVASurface = self.currentYUVASurface {
                yuvaSurface = currentYUVASurface
            } else {
                yuvaSurface = ImageYUVA420(width: dctCoefficients.yPlane.width, height: dctCoefficients.yPlane.height, rowAlignment: nil)
                // Fully rewritten by each frame. Planes handed out as .yuva are value
                // copies, so writing the next frame copies them first if still in use.
                self.currentYUVASurface = yuvaSurface
            }
            
            let currentCoefficients: DctCoefficientsYUVA420
            if let current = self.currentCoefficients {
                currentCoefficients = current
            } else {
                currentCoefficients = DctCoefficientsYUVA420(width: yuvaSurface.yPlane.width, height: yuvaSurface.yPlane.height)
                self.currentCoefficients = currentCoefficients
            }
            
            /*let deltaCoefficients: DctCoefficientsYUVA420
            if let current = self.deltaCoefficients {
                deltaCoefficients = current
            } else {
                deltaCoefficients = DctCoefficientsYUVA420(width: yuvaSurface.yPlane.width, height: yuvaSurface.yPlane.height)
                self.deltaCoefficients = deltaCoefficients
            }*/
            
            switch frameType {
            case 1:
                dctCoefficients.idct8x8(dctData: self.currentDctData, target: yuvaSurface)
                yuvaSurface.toCoefficients(target: currentCoefficients)
            default:
                dctCoefficients.idct4x4Add(dctData: self.currentDctData, target: currentCoefficients)
                //currentCoefficients.add(other: deltaCoefficients)
                
                currentCoefficients.toYUVA420(target: yuvaSurface)
            }
            
            self.currentFrame = CurrentFrame(index: index, duration: self.durationMapping[index], yuva: yuvaSurface)
        } catch {
            self.currentFrame = nil
            self.compressedDataReader = nil
        }
        
        return didLoop
    }
    
    func reset() {
        self.currentFrame = nil
    }
    
    func advance(advance: AnimationCacheItem.Advance, requestedFormat: AnimationCacheItemFrame.RequestedFormat) -> AnimationCacheItem.AdvanceResult? {
        var didLoop = false
        switch advance {
        case let .frames(count):
            for _ in 0 ..< count {
                if self.loadNextFrame() {
                    didLoop = true
                }
            }
        case let .duration(duration):
            var durationOverflow = duration
            while true {
                if let currentFrame = self.currentFrame {
                    currentFrame.remainingDuration -= durationOverflow
                    if currentFrame.remainingDuration <= 0.0 {
                        durationOverflow = -currentFrame.remainingDuration
                        if self.loadNextFrame() {
                            didLoop = true
                        }
                    } else {
                        break
                    }
                } else {
                    if self.loadNextFrame() {
                        didLoop = true
                    }
                    break
                }
            }
        }
        
        guard let currentFrame = self.currentFrame else {
            return nil
        }
        
        switch requestedFormat {
        case .rgba:
            let currentSurface = ImageARGB(width: currentFrame.yuva.yPlane.width, height: currentFrame.yuva.yPlane.height, rowAlignment: 32)
            currentFrame.yuva.toARGB(target: currentSurface)
            
            return AnimationCacheItem.AdvanceResult(
                frame: AnimationCacheItemFrame(format: .rgba(data: currentSurface.argbPlane.data, width: currentSurface.argbPlane.width, height: currentSurface.argbPlane.height, bytesPerRow: currentSurface.argbPlane.bytesPerRow), duration: currentFrame.duration),
                didLoop: didLoop
            )
        case .yuva:
            return AnimationCacheItem.AdvanceResult(
                frame: AnimationCacheItemFrame(
                    format: .yuva(
                        y: AnimationCacheItemFrame.Plane(
                            data: currentFrame.yuva.yPlane.data,
                            width: currentFrame.yuva.yPlane.width,
                            height: currentFrame.yuva.yPlane.height,
                            bytesPerRow: currentFrame.yuva.yPlane.bytesPerRow
                        ),
                        u: AnimationCacheItemFrame.Plane(
                            data: currentFrame.yuva.uPlane.data,
                            width: currentFrame.yuva.uPlane.width,
                            height: currentFrame.yuva.uPlane.height,
                            bytesPerRow: currentFrame.yuva.uPlane.bytesPerRow
                        ),
                        v: AnimationCacheItemFrame.Plane(
                            data: currentFrame.yuva.vPlane.data,
                            width: currentFrame.yuva.vPlane.width,
                            height: currentFrame.yuva.vPlane.height,
                            bytesPerRow: currentFrame.yuva.vPlane.bytesPerRow
                        ),
                        a: AnimationCacheItemFrame.Plane(
                            data: currentFrame.yuva.aPlane.data,
                            width: currentFrame.yuva.aPlane.width,
                            height: currentFrame.yuva.aPlane.height,
                            bytesPerRow: currentFrame.yuva.aPlane.bytesPerRow
                        )
                    ),
                    duration: currentFrame.duration
                ),
                didLoop: didLoop
            )
        }
    }
}

private func readData(data: Data, offset: Int, count: Int) -> Data {
    var result = Data(count: count)
    result.withUnsafeMutableBytes { bytes -> Void in
        data.withUnsafeBytes { dataBytes -> Void in
            memcpy(bytes.baseAddress!, dataBytes.baseAddress!.advanced(by: offset), count)
        }
    }
    return result
}

private func readUInt32(data: Data, offset: Int) -> UInt32 {
    var value: UInt32 = 0
    withUnsafeMutableBytes(of: &value, { bytes -> Void in
        data.withUnsafeBytes { dataBytes -> Void in
            memcpy(bytes.baseAddress!, dataBytes.baseAddress!.advanced(by: offset), 4)
        }
    })
    
    return value
}

private func loadUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    return readUInt32(data: data, offset: offset)
}

private func readFloat32(data: Data, offset: Int) -> Float32 {
    var value: Float32 = 0
    withUnsafeMutableBytes(of: &value, { bytes -> Void in
        data.withUnsafeBytes { dataBytes -> Void in
            memcpy(bytes.baseAddress!, dataBytes.baseAddress!.advanced(by: offset), 4)
        }
    })
    
    return value
}

private func writeUInt32(data: inout Data, value: UInt32) {
    var value: UInt32 = value
    withUnsafeBytes(of: &value, { bytes -> Void in
        data.count += 4
        data.withUnsafeMutableBytes { dataBytes -> Void in
            memcpy(dataBytes.baseAddress!.advanced(by: dataBytes.count - 4), bytes.baseAddress!, 4)
        }
    })
}

private func writeFloat32(data: inout Data, value: Float32) {
    var value: Float32 = value
    withUnsafeBytes(of: &value, { bytes -> Void in
        data.count += 4
        data.withUnsafeMutableBytes { dataBytes -> Void in
            memcpy(dataBytes.baseAddress!.advanced(by: dataBytes.count - 4), bytes.baseAddress!, 4)
        }
    })
}

// Format 8: [UInt32 raw length][UInt32 compressed length][compressed bytes] per block. A block
// ends at a frame boundary once it holds at least `blockSize` bytes, so no frame spans two blocks.
private final class BlockCompressedFileWriter: FrameStreamWriter {
    enum WriteError: Error {
        case generic
    }
    
    static let blockSize: Int = 64 * 1024
    
    private let file: ManagedFile
    private let algorithm: compression_algorithm
    private let scratch: UnsafeMutableRawPointer
    private var pending: UnsafeMutablePointer<UInt8>
    private var pendingCapacity: Int
    private var pendingCount: Int = 0
    private var output: UnsafeMutablePointer<UInt8>?
    private var outputCapacity: Int = 0
    private var didFail: Bool = false
    
    init(file: ManagedFile, codec: DCTAnimationCacheCodec) {
        self.file = file
        self.algorithm = codec.algorithm
        self.scratch = UnsafeMutableRawPointer.allocate(byteCount: max(1, compression_encode_scratch_buffer_size(codec.algorithm)), alignment: 16)
        self.pendingCapacity = BlockCompressedFileWriter.blockSize * 2
        self.pending = UnsafeMutablePointer<UInt8>.allocate(capacity: self.pendingCapacity)
    }
    
    deinit {
        self.scratch.deallocate()
        self.pending.deallocate()
        self.output?.deallocate()
    }
    
    func write(bytes: UnsafePointer<UInt8>, count: Int) throws {
        if self.didFail {
            throw WriteError.generic
        }
        if self.pendingCount + count > self.pendingCapacity {
            var capacity = self.pendingCapacity
            while self.pendingCount + count > capacity {
                capacity *= 2
            }
            let pending = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            pending.update(from: self.pending, count: self.pendingCount)
            self.pending.deallocate()
            self.pending = pending
            self.pendingCapacity = capacity
        }
        self.pending.advanced(by: self.pendingCount).update(from: bytes, count: count)
        self.pendingCount += count
    }
    
    func endFrame() throws {
        if self.pendingCount >= BlockCompressedFileWriter.blockSize {
            try self.flushBlock()
        }
    }
    
    func flush() throws {
        if self.didFail {
            throw WriteError.generic
        }
        if self.pendingCount != 0 {
            try self.flushBlock()
        }
    }
    
    private func flushBlock() throws {
        // Room for incompressible input, which these codecs expand only slightly.
        let capacity = 8 + self.pendingCount + self.pendingCount / 8 + 4096
        let output: UnsafeMutablePointer<UInt8>
        if let current = self.output, self.outputCapacity >= capacity {
            output = current
        } else {
            self.output?.deallocate()
            output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            self.output = output
            self.outputCapacity = capacity
        }
        let compressedCount = compression_encode_buffer(output.advanced(by: 8), capacity - 8, self.pending, self.pendingCount, self.scratch, self.algorithm)
        if compressedCount <= 0 {
            self.didFail = true
            throw WriteError.generic
        }
        var rawLength = UInt32(self.pendingCount)
        var compressedLength = UInt32(compressedCount)
        memcpy(output, &rawLength, 4)
        memcpy(output.advanced(by: 4), &compressedLength, 4)
        if self.file.write(output, count: 8 + compressedCount) != 8 + compressedCount {
            self.didFail = true
            throw WriteError.generic
        }
        self.pendingCount = 0
    }
}

// Reads a format 8 block stream, one decoded block at a time.
private final class BlockDecompressedData: FrameStreamReader {
    enum ReadError: Error {
        case didReadToEnd
    }
    
    private static let maxBlockLength: Int = 64 * 1024 * 1024
    
    private let compressedData: Data
    private var position: Int
    private let end: Int
    private let algorithm: compression_algorithm
    private let scratch: UnsafeMutableRawPointer
    private var block: UnsafeMutablePointer<UInt8>?
    private var blockCapacity: Int = 0
    private var blockLength: Int = 0
    private var blockPosition: Int = 0
    
    init(compressedData: Data, dataRange: Range<Int>, codec: DCTAnimationCacheCodec) {
        self.compressedData = compressedData
        self.position = dataRange.lowerBound
        self.end = dataRange.upperBound
        self.algorithm = codec.algorithm
        self.scratch = UnsafeMutableRawPointer.allocate(byteCount: max(1, compression_decode_scratch_buffer_size(codec.algorithm)), alignment: 16)
    }
    
    deinit {
        self.scratch.deallocate()
        self.block?.deallocate()
    }
    
    private func loadNextBlock() throws {
        if self.position + 8 > self.end {
            throw ReadError.didReadToEnd
        }
        // The global readUInt32(data:offset:) is shadowed by this class's readUInt32().
        let rawLength = Int(loadUInt32(self.compressedData, self.position))
        let compressedLength = Int(loadUInt32(self.compressedData, self.position + 4))
        self.position += 8
        if rawLength <= 0 || rawLength > BlockDecompressedData.maxBlockLength || compressedLength <= 0 || self.position + compressedLength > self.end {
            self.position = self.end
            throw ReadError.didReadToEnd
        }
        let block: UnsafeMutablePointer<UInt8>
        if let current = self.block, self.blockCapacity >= rawLength {
            block = current
        } else {
            self.block?.deallocate()
            block = UnsafeMutablePointer<UInt8>.allocate(capacity: rawLength)
            self.block = block
            self.blockCapacity = rawLength
        }
        let position = self.position
        let algorithm = self.algorithm
        let scratch = self.scratch
        let decodedLength = self.compressedData.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else {
                return 0
            }
            return compression_decode_buffer(block, rawLength, base.assumingMemoryBound(to: UInt8.self).advanced(by: position), compressedLength, scratch, algorithm)
        }
        if decodedLength != rawLength {
            self.position = self.end
            throw ReadError.didReadToEnd
        }
        self.position += compressedLength
        self.blockLength = rawLength
        self.blockPosition = 0
    }
    
    func read(bytes: UnsafeMutablePointer<UInt8>, count: Int) throws {
        var copied = 0
        while copied < count {
            if self.blockPosition == self.blockLength {
                try self.loadNextBlock()
            }
            guard let block = self.block else {
                throw ReadError.didReadToEnd
            }
            let available = min(count - copied, self.blockLength - self.blockPosition)
            bytes.advanced(by: copied).update(from: block.advanced(by: self.blockPosition), count: available)
            self.blockPosition += available
            copied += available
        }
    }
}

private final class CompressedFileWriter: FrameStreamWriter {
    enum WriteError: Error {
        case generic
    }
    
    private let file: ManagedFile
    private let stream: UnsafeMutablePointer<compression_stream>
    
    private let tempOutputBufferSize: Int = 64 * 1024
    private let tempOutputBuffer: UnsafeMutablePointer<UInt8>
    private let tempInputBufferCapacity: Int = 64 * 1024
    private let tempInputBuffer: UnsafeMutablePointer<UInt8>
    private var tempInputBufferSize: Int = 0
    
    private var didFail: Bool = false
    
    init?(file: ManagedFile) {
        self.file = file
        
        self.stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        guard compression_stream_init(self.stream, COMPRESSION_STREAM_ENCODE, algorithm) != COMPRESSION_STATUS_ERROR else {
            self.stream.deallocate()
            return nil
        }
        
        self.tempOutputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: self.tempOutputBufferSize)
        self.tempInputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: self.tempInputBufferCapacity)
    }
    
    deinit {
        compression_stream_destroy(self.stream)
        self.stream.deallocate()
        self.tempOutputBuffer.deallocate()
        self.tempInputBuffer.deallocate()
    }
    
    private func flushBuffer() throws {
        if self.didFail {
            throw WriteError.generic
        }
        
        if self.tempInputBufferSize <= 0 {
            return
        }
        
        self.stream.pointee.src_ptr = UnsafePointer(self.tempInputBuffer)
        self.stream.pointee.src_size = self.tempInputBufferSize
        
        while true {
            self.stream.pointee.dst_ptr = self.tempOutputBuffer
            self.stream.pointee.dst_size = self.tempOutputBufferSize
            
            let status = compression_stream_process(self.stream, 0)
            if status == COMPRESSION_STATUS_ERROR {
                self.didFail = true
                throw WriteError.generic
            }
            
            let writtenBytes = self.tempOutputBufferSize - self.stream.pointee.dst_size
            if writtenBytes > 0 {
                let _ = self.file.write(self.tempOutputBuffer, count: writtenBytes)
            }
            
            if status == COMPRESSION_STATUS_END {
                break
            } else {
                if self.stream.pointee.src_size == 0 {
                    break
                }
            }
        }
        
        self.tempInputBufferSize = 0
    }
    
    func write(bytes: UnsafePointer<UInt8>, count: Int) throws {
        var writtenBytes = 0
        while writtenBytes < count {
            let availableBytes = self.tempInputBufferCapacity - self.tempInputBufferSize
            if availableBytes == 0 {
                try flushBuffer()
            } else {
                let writeCount = min(availableBytes, count - writtenBytes)
                
                memcpy(self.tempInputBuffer.advanced(by: self.tempInputBufferSize), bytes.advanced(by: writtenBytes), writeCount)
                self.tempInputBufferSize += writeCount
                writtenBytes += writeCount
            }
        }
    }
    
    func endFrame() throws {
    }
    
    func flush() throws {
        if self.didFail {
            throw WriteError.generic
        }
        
        try self.flushBuffer()
        
        while true {
            self.stream.pointee.dst_ptr = self.tempOutputBuffer
            self.stream.pointee.dst_size = self.tempOutputBufferSize
            
            let status = compression_stream_process(self.stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            if status == COMPRESSION_STATUS_ERROR {
                self.didFail = true
                throw WriteError.generic
            }
            
            let writtenBytes = self.tempOutputBufferSize - self.stream.pointee.dst_size
            if writtenBytes > 0 {
                let _ = self.file.write(self.tempOutputBuffer, count: writtenBytes)
            }
            
            if status == COMPRESSION_STATUS_END {
                break
            }
        }
    }
    
    func writeUInt32(_ value: UInt32) throws {
        var value: UInt32 = value
        try withUnsafeBytes(of: &value, { bytes -> Void in
            try self.write(bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 4)
        })
    }
    
    func writeFloat32(_ value: Float32) throws {
        var value: Float32 = value
        try withUnsafeBytes(of: &value, { bytes -> Void in
            try self.write(bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 4)
        })
    }
}

private final class DecompressedData: FrameStreamReader {
    enum ReadError: Error {
        case didReadToEnd
    }
    
    private let compressedData: Data
    private let dataRange: Range<Int>
    private let stream: UnsafeMutablePointer<compression_stream>
    private var isComplete = false
    
    init?(compressedData: Data, dataRange: Range<Int>) {
        self.compressedData = compressedData
        self.dataRange = dataRange
        
        self.stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        guard compression_stream_init(self.stream, COMPRESSION_STREAM_DECODE, algorithm) != COMPRESSION_STATUS_ERROR else {
            self.stream.deallocate()
            return nil
        }
        
        self.compressedData.withUnsafeBytes { bytes in
            self.stream.pointee.src_ptr = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: dataRange.lowerBound)
            self.stream.pointee.src_size = dataRange.upperBound - dataRange.lowerBound
        }
    }
    
    deinit {
        compression_stream_destroy(self.stream)
        self.stream.deallocate()
    }
    
    func read(bytes: UnsafeMutablePointer<UInt8>, count: Int) throws {
        if self.isComplete {
            throw ReadError.didReadToEnd
        }
        
        self.stream.pointee.dst_ptr = bytes
        self.stream.pointee.dst_size = count
        
        let status = compression_stream_process(self.stream, 0)
        
        if status == COMPRESSION_STATUS_ERROR {
            self.isComplete = true
            throw ReadError.didReadToEnd
        } else if status == COMPRESSION_STATUS_END {
            if self.stream.pointee.src_size == 0 {
                self.isComplete = true
            }
        }
         
        if self.stream.pointee.dst_size != 0 {
            throw ReadError.didReadToEnd
        }
    }
    
    func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        try withUnsafeMutableBytes(of: &value, { bytes -> Void in
            try self.read(bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 4)
        })
        return value
    }

    func readFloat32() throws -> Float32 {
        var value: Float32 = 0
        try withUnsafeMutableBytes(of: &value, { bytes -> Void in
            try self.read(bytes: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 4)
        })
        return value
    }
}

private enum LoadItemError: Error {
    case dataError
}

private func isUsableCachedItemDimension(_ value: UInt32) -> Bool {
    return value > 0 && value <= 4096 && value % 16 == 0
}

func loadItem(path: String) throws -> AnimationCacheItem {
    guard let compressedData = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
        throw LoadItemError.dataError
    }
    
    var offset: Int = 0
    let dataLength = compressedData.count
    
    if offset + 4 > dataLength {
        throw LoadItemError.dataError
    }
    let formatVersion = readUInt32(data: compressedData, offset: offset)
    offset += 4
    if formatVersion != 6 && formatVersion != 7 && formatVersion != 8 {
        throw LoadItemError.dataError
    }
    
    var codec: DCTAnimationCacheCodec?
    if formatVersion >= 8 {
        if offset + 1 > dataLength {
            throw LoadItemError.dataError
        }
        // A codec this OS cannot decode (or an unknown one) is converted again.
        guard let value = DCTAnimationCacheCodec(rawValue: compressedData[compressedData.startIndex + offset]), isDecodable(value) else {
            throw LoadItemError.dataError
        }
        codec = value
        offset += 1
    }
    
    if offset + 4 > dataLength {
        throw LoadItemError.dataError
    }
    let width = readUInt32(data: compressedData, offset: offset)
    offset += 4
    
    if offset + 4 > dataLength {
        throw LoadItemError.dataError
    }
    let height = readUInt32(data: compressedData, offset: offset)
    offset += 4
    // The writer rounds both up to 16; the DCT blocks of any other size do not fit the planes.
    // The bound keeps width * height * 2 from overflowing and the buffers allocatable.
    if !isUsableCachedItemDimension(width) || !isUsableCachedItemDimension(height) {
        throw LoadItemError.dataError
    }
    
    if offset + 4 > dataLength {
        throw LoadItemError.dataError
    }
    let dctLumaTableLength = readUInt32(data: compressedData, offset: offset)
    offset += 4
    
    if offset + Int(dctLumaTableLength) > dataLength {
        throw LoadItemError.dataError
    }
    let dctLumaData = readData(data: compressedData, offset: offset, count: Int(dctLumaTableLength))
    offset += Int(dctLumaTableLength)
    
    if offset + 4 > dataLength {
        throw LoadItemError.dataError
    }
    let dctChromaTableLength = readUInt32(data: compressedData, offset: offset)
    offset += 4
    
    if offset + Int(dctChromaTableLength) > dataLength {
        throw LoadItemError.dataError
    }
    let dctChromaData = readData(data: compressedData, offset: offset, count: Int(dctChromaTableLength))
    offset += Int(dctChromaTableLength)
    
    if offset + 4 > dataLength {
        throw LoadItemError.dataError
    }
    let dctDeltaTableLength = readUInt32(data: compressedData, offset: offset)
    offset += 4
    
    if offset + Int(dctDeltaTableLength) > dataLength {
        throw LoadItemError.dataError
    }
    let dctDeltaData = readData(data: compressedData, offset: offset, count: Int(dctDeltaTableLength))
    offset += Int(dctDeltaTableLength)
    
    if offset + 4 > dataLength {
        throw LoadItemError.dataError
    }
    let contentLength = Int(readUInt32(data: compressedData, offset: offset))
    offset += 4
    
    if contentLength < 0 || offset + contentLength > dataLength {
        throw LoadItemError.dataError
    }
    let compressedFrameDataRange = offset ..< (offset + contentLength)
    offset += contentLength
    
    if offset + 4 > dataLength {
        throw LoadItemError.dataError
    }
    let frameCount = Int(readUInt32(data: compressedData, offset: offset))
    offset += 4
    
    var frameMapping: [AnimationCacheItemAccessor.FrameInfo] = []
    for _ in 0 ..< frameCount {
        if offset + 4 > dataLength {
            throw LoadItemError.dataError
        }
        let frameDuration = readFloat32(data: compressedData, offset: offset)
        offset += 4
        // Playback loops forever on zero or negative durations and overflows its frame count on tiny ones.
        // Infinity (a frame rate of 0) is a still frame and is kept.
        if frameDuration.isNaN || frameDuration < 0.0001 {
            throw LoadItemError.dataError
        }
        
        frameMapping.append(AnimationCacheItemAccessor.FrameInfo(duration: Double(frameDuration)))
    }
    
    // Playback indexes the duration table by frame.
    if frameMapping.isEmpty {
        throw LoadItemError.dataError
    }
    
    guard let dctData = DctData(lumaTable: dctLumaData, chromaTable: dctChromaData, deltaTable: dctDeltaData) else {
        throw LoadItemError.dataError
    }
    
    let itemAccessor = AnimationCacheItemAccessor(data: compressedData, formatVersion: formatVersion, codec: codec, range: compressedFrameDataRange, frameMapping: frameMapping, width: Int(width), height: Int(height), dctData: dctData)
    
    return AnimationCacheItem(numFrames: frameMapping.count, advanceImpl: { advance, requestedFormat in
        return itemAccessor.advance(advance: advance, requestedFormat: requestedFormat)
    }, resetImpl: {
        itemAccessor.reset()
    })
}

private func adaptItemFromHigherResolution(currentQueue: Queue, itemPath: String, width: Int, height: Int, itemDirectoryPath: String, higherResolutionPath: String, allocateTempFile: @escaping () -> String, updateStorageStats: @escaping (String, Int64) -> Void) -> AnimationCacheItem? {
    guard let higherResolutionItem = try? loadItem(path: higherResolutionPath) else {
        return nil
    }
    guard let writer = AnimationCacheItemWriterImpl(queue: currentQueue, allocateTempFile: allocateTempFile, completion: {
        _ in
    }) else {
        return nil
    }
    
    do {
        for _ in 0 ..< higherResolutionItem.numFrames {
            try writer.addYUV(with: { yuva in
                guard let frame = higherResolutionItem.advance(advance: .frames(1), requestedFormat: .yuva(rowAlignment: yuva.yPlane.rowAlignment)) else {
                    return nil
                }
                switch frame.frame.format {
                case .rgba:
                    return nil
                case let .yuva(y, u, v, a):
                    yuva.yPlane.copyScaled(fromPlane: y)
                    yuva.uPlane.copyScaled(fromPlane: u)
                    yuva.vPlane.copyScaled(fromPlane: v)
                    yuva.aPlane.copyScaled(fromPlane: a)
                }
                
                return frame.frame.duration
            }, proposedWidth: width, proposedHeight: height, insertKeyframe: true)
        }
        
        guard let result = try writer.finishInternal() else {
            return nil
        }
        guard let _ = try? FileManager.default.createDirectory(at: URL(fileURLWithPath: itemDirectoryPath), withIntermediateDirectories: true, attributes: nil) else {
            return nil
        }
        let _ = try? FileManager.default.removeItem(atPath: itemPath)
        guard let _ = try? FileManager.default.moveItem(atPath: result.animationPath, toPath: itemPath) else {
            return nil
        }
        // The converted item was written once, to the file just moved into place.
        DiskWriteAccounting.shared.add(DiskWriteCategory.animationCache, bytes: Int(fileSize(itemPath) ?? 0))
        if let size = fileSize(itemPath) {
            updateStorageStats(itemPath, size)
        }
        adaptationSizeIndex.noteSize(width: width, height: height)
        
        guard let item = try? loadItem(path: itemPath) else {
            return nil
        }
        return item
    } catch {
        return nil
    }
}

private func generateFirstFrameFromItem(currentQueue: Queue, itemPath: String, animationItemPath: String, allocateTempFile: @escaping () -> String, updateStorageStats: @escaping (String, Int64) -> Void) -> Bool {
    guard let animationItem = try? loadItem(path: animationItemPath) else {
        return false
    }
    guard let writer = AnimationCacheItemWriterImpl(queue: currentQueue, allocateTempFile: allocateTempFile, completion: { _ in
    }) else {
        return false
    }
    
    do {
        for _ in 0 ..< min(1, animationItem.numFrames) {
            guard let frame = animationItem.advance(advance: .frames(1), requestedFormat: .yuva(rowAlignment: 1)) else {
                return false
            }
            switch frame.frame.format {
            case .rgba:
                return false
            case let .yuva(y, u, v, a):
                try writer.addYUV(with: { yuva in
                    assert(yuva.yPlane.bytesPerRow == y.bytesPerRow)
                    assert(yuva.uPlane.bytesPerRow == u.bytesPerRow)
                    assert(yuva.vPlane.bytesPerRow == v.bytesPerRow)
                    assert(yuva.aPlane.bytesPerRow == a.bytesPerRow)
                    
                    yuva.yPlane.copyScaled(fromPlane: y)
                    yuva.uPlane.copyScaled(fromPlane: u)
                    yuva.vPlane.copyScaled(fromPlane: v)
                    yuva.aPlane.copyScaled(fromPlane: a)
                    
                    return frame.frame.duration
                }, proposedWidth: y.width, proposedHeight: y.height, insertKeyframe: true)
            }
        }
        
        guard let result = try writer.finishInternal() else {
            return false
        }
        
        let _ = try? FileManager.default.removeItem(atPath: itemPath)
        guard let _ = try? FileManager.default.moveItem(atPath: result.animationPath, toPath: itemPath) else {
            return false
        }
        // The converted item was written once, to the file just moved into place.
        DiskWriteAccounting.shared.add(DiskWriteCategory.animationCache, bytes: Int(fileSize(itemPath) ?? 0))
        if let size = fileSize(itemPath) {
            updateStorageStats(itemPath, size)
        }
        return true
    } catch {
        return false
    }
}

// Tests: called with the directory while it is being listed.
var adaptationSizeIndexListingHook: ((String) -> Void)?

// Item sizes are few (a handful of emoji and sticker sizes), but each of the 256 shard directories
// holds 1/256 of all items. A first-frame miss listed its whole directory to find a larger size to
// scale down; now each directory is listed once per process (that call answers exactly as before),
// and later misses stat the sizes seen so far. Files this process writes record their size here;
// one written by another process (an extension) at a size this process has not seen since the
// listing is missed, and the item is converted instead.
private final class AdaptationSizeIndex {
    private struct Size: Hashable {
        let width: Int
        let height: Int
    }
    
    private let lock = NSLock()
    private var sizes = Set<Size>()
    private var listedDirectories = Set<String>()
    
    func noteSize(width: Int, height: Int) {
        self.lock.lock()
        self.sizes.insert(Size(width: width, height: height))
        self.lock.unlock()
    }
    
    // The lock guards only the two sets. Listing and stat are file I/O and run without it: the
    // main thread (getFirstFrameSynchronously) must not wait for a fetch queue's listing of
    // another directory. Two threads may list the same directory once each; that is harmless.
    func findHigherResolutionFile(itemDirectoryPath: String, baseName: String, baseSuffix: String, width: Int, height: Int) -> String? {
        self.lock.lock()
        let isListed = self.listedDirectories.contains(itemDirectoryPath)
        self.lock.unlock()
        
        if !isListed {
            var listedSizes: [Size] = []
            var candidates: [(path: String, width: Int, height: Int)] = []
            adaptationSizeIndexListingHook?(itemDirectoryPath)
            if let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: itemDirectoryPath), includingPropertiesForKeys: nil, options: .skipsSubdirectoryDescendants, errorHandler: nil) {
                for url in enumerator {
                    guard let url = url as? URL else {
                        continue
                    }
                    let fileName = url.lastPathComponent
                    // Every item name is "<md5>_<width>x<height>", optionally with "-f".
                    if let size = parseItemSize(fileName: fileName) {
                        listedSizes.append(Size(width: size.width, height: size.height))
                    }
                    if fileName.hasPrefix(baseName) {
                        let scanner = Scanner(string: fileName)
                        guard scanner.scanString(baseName) != nil else {
                            continue
                        }
                        guard let itemWidth = scanner.scanInt() else {
                            continue
                        }
                        guard scanner.scanString("x") != nil else {
                            continue
                        }
                        guard let itemHeight = scanner.scanInt() else {
                            continue
                        }
                        if !baseSuffix.isEmpty {
                            guard scanner.scanString(baseSuffix) != nil else {
                                continue
                            }
                        }
                        guard scanner.isAtEnd else {
                            continue
                        }
                        if itemWidth > width && itemHeight > height {
                            candidates.append((url.path, itemWidth, itemHeight))
                        }
                    }
                }
            }
            // Marked as listed only once its sizes are in, so a concurrent lookup never stats
            // an incomplete set.
            self.lock.lock()
            self.sizes.formUnion(listedSizes)
            self.listedDirectories.insert(itemDirectoryPath)
            self.lock.unlock()
            if !candidates.isEmpty {
                candidates.sort(by: { $0.width < $1.width })
                return candidates[0].path
            }
            return nil
        }
        
        self.lock.lock()
        let larger = self.sizes.filter { $0.width > width && $0.height > height }.sorted(by: { lhs, rhs in
            if lhs.width != rhs.width {
                return lhs.width < rhs.width
            }
            return lhs.height < rhs.height
        })
        self.lock.unlock()
        for size in larger {
            let path = "\(itemDirectoryPath)/\(baseName)\(size.width)x\(size.height)\(baseSuffix)"
            var value = stat()
            if stat(path, &value) == 0 {
                return path
            }
        }
        return nil
    }
}

// "<32 hex>_<width>x<height>" with an optional "-f".
private func parseItemSize(fileName: String) -> (width: Int, height: Int)? {
    let utf8 = Array(fileName.utf8)
    guard utf8.count > 33, utf8[32] == UInt8(ascii: "_") else {
        return nil
    }
    var index = 33
    func number() -> Int? {
        var value = 0
        let start = index
        while index < utf8.count, utf8[index] >= UInt8(ascii: "0"), utf8[index] <= UInt8(ascii: "9"), index - start < 6 {
            value = value * 10 + Int(utf8[index] - UInt8(ascii: "0"))
            index += 1
        }
        return index > start ? value : nil
    }
    guard let width = number(), index < utf8.count, utf8[index] == UInt8(ascii: "x") else {
        return nil
    }
    index += 1
    guard let height = number() else {
        return nil
    }
    if index != utf8.count && !(index + 2 == utf8.count && utf8[index] == UInt8(ascii: "-") && utf8[index + 1] == UInt8(ascii: "f")) {
        return nil
    }
    return (width, height)
}

private let adaptationSizeIndex = AdaptationSizeIndex()

private func findHigherResolutionFileForAdaptation(itemDirectoryPath: String, baseName: String, baseSuffix: String, width: Int, height: Int) -> String? {
    return adaptationSizeIndex.findHigherResolutionFile(itemDirectoryPath: itemDirectoryPath, baseName: baseName, baseSuffix: baseSuffix, width: width, height: height)
}

private func fileExists(_ path: String) -> Bool {
    var value = stat()
    return stat(path, &value) == 0
}

// Moves a converted item into place. Its first-frame file is made from it only when there is none:
// the first-frame conversion has usually written it already, from the same source frame.
private func storeConvertedItem(resultPath: String, itemDirectoryPath: String, itemPath: String, itemFirstFramePath: String, width: Int, height: Int, currentQueue: Queue, allocateTempFile: @escaping () -> String, updateStorageStats: @escaping (String, Int64) -> Void) -> Bool {
    guard let _ = try? FileManager.default.createDirectory(at: URL(fileURLWithPath: itemDirectoryPath), withIntermediateDirectories: true, attributes: nil) else {
        return false
    }
    let _ = try? FileManager.default.removeItem(atPath: itemPath)
    guard let _ = try? FileManager.default.moveItem(atPath: resultPath, toPath: itemPath) else {
        return false
    }
    // The converted item was written once, to the file just moved into place.
    DiskWriteAccounting.shared.add(DiskWriteCategory.animationCache, bytes: Int(fileSize(itemPath) ?? 0))
    if let size = fileSize(itemPath) {
        updateStorageStats(itemPath, size)
    }
    adaptationSizeIndex.noteSize(width: width, height: height)
    
    if !fileExists(itemFirstFramePath) {
        let _ = generateFirstFrameFromItem(currentQueue: currentQueue, itemPath: itemFirstFramePath, animationItemPath: itemPath, allocateTempFile: allocateTempFile, updateStorageStats: updateStorageStats)
    }
    return true
}

public final class DCTAnimationCacheImpl: AnimationCache {
    private final class Impl {
        private struct ItemKey: Hashable {
            var id: String
            var width: Int
            var height: Int
        }
        
        private final class ItemContext {
            let subscribers = Bag<(AnimationCacheItemResult) -> Void>()
            let disposable = MetaDisposable()
            
            deinit {
                self.disposable.dispose()
            }
        }
        
        private let queue: Queue
        private let basePath: String
        private let allocateTempFile: () -> String
        private let updateStorageStats: (String, Int64) -> Void
        
        private let fetchQueues: [Queue]
        private var nextFetchQueueIndex: Int = 0
        // Puts converted items in place. Not a fetch queue: other items' conversions (a few hundred
        // milliseconds each) queue there, and a finished item waited behind all of them. Not the
        // cache queue either, so cache hits do not wait for file work.
        private let storeQueue: Queue
        
        private var itemContexts: [ItemKey: ItemContext] = [:]
        
        init(queue: Queue, basePath: String, allocateTempFile: @escaping () -> String, updateStorageStats: @escaping (String, Int64) -> Void) {
            self.queue = queue
            
            let fetchQueueCount: Int
            if ProcessInfo.processInfo.processorCount > 2 {
                fetchQueueCount = 3
            } else {
                fetchQueueCount = 2
            }
            
            self.fetchQueues = (0 ..< fetchQueueCount).map { i in Queue(name: "DCTAnimationCacheImpl-Fetch\(i)", qos: .default) }
            self.storeQueue = Queue(name: "DCTAnimationCacheImpl-Store", qos: .userInitiated)
            self.basePath = basePath
            self.allocateTempFile = allocateTempFile
            self.updateStorageStats = updateStorageStats
        }
        
        deinit {
        }
        
        func get(sourceId: String, size: CGSize, fetch: @escaping (AnimationCacheFetchOptions) -> Disposable, updateResult: @escaping (AnimationCacheItemResult) -> Void) -> Disposable {
            let sourceIdPath = itemSubpath(hashString: md5Hash(sourceId), width: Int(size.width), height: Int(size.height))
            let itemDirectoryPath = "\(self.basePath)/\(sourceIdPath.directory)"
            let itemPath = "\(itemDirectoryPath)/\(sourceIdPath.fileName)"
            let itemFirstFramePath = "\(itemDirectoryPath)/\(sourceIdPath.fileName)-f"
            
            if cachedItemExists(path: itemPath), let item = try? loadItem(path: itemPath) {
                updateResult(AnimationCacheItemResult(item: item, isFinal: true))
                
                return EmptyDisposable
            }
            let key = ItemKey(id: sourceId, width: Int(size.width), height: Int(size.height))
            
            let itemContext: ItemContext
            var beginFetch = false
            if let current = self.itemContexts[key] {
                itemContext = current
            } else {
                itemContext = ItemContext()
                self.itemContexts[key] = itemContext
                beginFetch = true
            }
            
            let queue = self.queue
            let index = itemContext.subscribers.add(updateResult)
            
            updateResult(AnimationCacheItemResult(item: nil, isFinal: false))
            
            if beginFetch {
                let fetchQueueIndex = self.nextFetchQueueIndex
                self.nextFetchQueueIndex += 1
                let allocateTempFile = self.allocateTempFile
                let updateStorageStats = self.updateStorageStats
                let fetchQueue = self.fetchQueues[fetchQueueIndex % self.fetchQueues.count]
                let storeQueue = self.storeQueue
                guard let writer = AnimationCacheItemWriterImpl(queue: fetchQueue, allocateTempFile: self.allocateTempFile, completion: { [weak self, weak itemContext] result in
                    queue.async {
                        guard let strongSelf = self, let itemContext = itemContext, itemContext === strongSelf.itemContexts[key] else {
                            // Nobody waits for this item any more (it was cancelled and finished anyway): the
                            // temporary file would stay in the temp directory until the next launch.
                            if let result {
                                let _ = try? FileManager.default.removeItem(atPath: result.animationPath)
                            }
                            return
                        }
                        
                        guard let result = result else {
                            strongSelf.itemContexts.removeValue(forKey: key)
                            return
                        }
                        // The file work runs on the store queue, so cache hits on this queue do not
                        // wait for it, and it does not wait for conversions queued on the fetch queue.
                        // The context stays registered meanwhile: a `get` for the same item joins it
                        // instead of converting again.
                        storeQueue.async {
                            let stored = storeConvertedItem(resultPath: result.animationPath, itemDirectoryPath: itemDirectoryPath, itemPath: itemPath, itemFirstFramePath: itemFirstFramePath, width: Int(size.width), height: Int(size.height), currentQueue: storeQueue, allocateTempFile: allocateTempFile, updateStorageStats: updateStorageStats)
                            queue.async {
                                guard let strongSelf = self, itemContext === strongSelf.itemContexts[key] else {
                                    return
                                }
                                strongSelf.itemContexts.removeValue(forKey: key)
                                if !stored {
                                    return
                                }
                                for f in itemContext.subscribers.copyItems() {
                                    guard let item = try? loadItem(path: itemPath) else {
                                        continue
                                    }
                                    f(AnimationCacheItemResult(item: item, isFinal: true))
                                }
                            }
                        }
                    }
                }) else {
                    return EmptyDisposable
                }
                
                let fetchDisposable = MetaDisposable()
                fetchDisposable.set(fetch(AnimationCacheFetchOptions(size: size, writer: writer, firstFrameOnly: false)))
                
                itemContext.disposable.set(ActionDisposable { [weak writer] in
                    if let writer = writer {
                        writer.isCancelled = true
                    }
                    
                    fetchDisposable.dispose()
                })
            }
            
            return ActionDisposable { [weak self, weak itemContext] in
                queue.async {
                    guard let strongSelf = self, let itemContext = itemContext, itemContext === strongSelf.itemContexts[key] else {
                        return
                    }
                    itemContext.subscribers.remove(index)
                    if itemContext.subscribers.isEmpty {
                        itemContext.disposable.dispose()
                        strongSelf.itemContexts.removeValue(forKey: key)
                    }
                }
            }
        }
        
        static func getFirstFrameSynchronously(basePath: String, sourceId: String, size: CGSize, allocateTempFile: @escaping () -> String, updateStorageStats: @escaping (String, Int64) -> Void) -> AnimationCacheItem? {
            let hashString = md5Hash(sourceId)
            let sourceIdPath = itemSubpath(hashString: hashString, width: Int(size.width), height: Int(size.height))
            let itemDirectoryPath = "\(basePath)/\(sourceIdPath.directory)"
            let itemFirstFramePath = "\(itemDirectoryPath)/\(sourceIdPath.fileName)-f"
            
            if cachedItemExists(path: itemFirstFramePath) {
                if let item = try? loadItem(path: itemFirstFramePath) {
                    return item
                }
            }
            
            if let adaptationItemPath = findHigherResolutionFileForAdaptation(itemDirectoryPath: itemDirectoryPath, baseName: "\(hashString)_", baseSuffix: "-f", width: Int(size.width), height: Int(size.height)) {
                if let adaptedItem = adaptItemFromHigherResolution(currentQueue: .mainQueue(), itemPath: itemFirstFramePath, width: Int(size.width), height: Int(size.height), itemDirectoryPath: itemDirectoryPath, higherResolutionPath: adaptationItemPath, allocateTempFile: allocateTempFile, updateStorageStats: updateStorageStats) {
                    return adaptedItem
                }
            }
            
            return nil
        }
        
        static func getFirstFrame(queue: Queue, basePath: String, sourceId: String, size: CGSize, allocateTempFile: @escaping () -> String, updateStorageStats: @escaping (String, Int64) -> Void, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (AnimationCacheItemResult) -> Void) -> Disposable {
            let hashString = md5Hash(sourceId)
            let sourceIdPath = itemSubpath(hashString: hashString, width: Int(size.width), height: Int(size.height))
            let itemDirectoryPath = "\(basePath)/\(sourceIdPath.directory)"
            let itemFirstFramePath = "\(itemDirectoryPath)/\(sourceIdPath.fileName)-f"
            
            if cachedItemExists(path: itemFirstFramePath), let item = try? loadItem(path: itemFirstFramePath) {
                completion(AnimationCacheItemResult(item: item, isFinal: true))
                return EmptyDisposable
            }
            
            if let adaptationItemPath = findHigherResolutionFileForAdaptation(itemDirectoryPath: itemDirectoryPath, baseName: "\(hashString)_", baseSuffix: "-f", width: Int(size.width), height: Int(size.height)) {
                if let adaptedItem = adaptItemFromHigherResolution(currentQueue: .mainQueue(), itemPath: itemFirstFramePath, width: Int(size.width), height: Int(size.height), itemDirectoryPath: itemDirectoryPath, higherResolutionPath: adaptationItemPath, allocateTempFile: allocateTempFile, updateStorageStats: updateStorageStats) {
                    completion(AnimationCacheItemResult(item: adaptedItem, isFinal: true))
                    return EmptyDisposable
                }
            }
            
            if let fetch = fetch {
                completion(AnimationCacheItemResult(item: nil, isFinal: false))
                
                guard let writer = AnimationCacheItemWriterImpl(queue: queue, allocateTempFile: allocateTempFile, completion: { result in
                    queue.async {
                        guard let result = result else {
                            completion(AnimationCacheItemResult(item: nil, isFinal: true))
                            return
                        }
                        guard let _ = try? FileManager.default.createDirectory(at: URL(fileURLWithPath: itemDirectoryPath), withIntermediateDirectories: true, attributes: nil) else {
                            completion(AnimationCacheItemResult(item: nil, isFinal: true))
                            return
                        }
                        let _ = try? FileManager.default.removeItem(atPath: itemFirstFramePath)
                        guard let _ = try? FileManager.default.moveItem(atPath: result.animationPath, toPath: itemFirstFramePath) else {
                            completion(AnimationCacheItemResult(item: nil, isFinal: true))
                            return
                        }
                        DiskWriteAccounting.shared.add(DiskWriteCategory.animationCache, bytes: Int(fileSize(itemFirstFramePath) ?? 0))
                        if let size = fileSize(itemFirstFramePath) {
                            updateStorageStats(itemFirstFramePath, size)
                        }
                        adaptationSizeIndex.noteSize(width: Int(size.width), height: Int(size.height))
                        guard let item = try? loadItem(path: itemFirstFramePath) else {
                            completion(AnimationCacheItemResult(item: nil, isFinal: true))
                            return
                        }
                        
                        completion(AnimationCacheItemResult(item: item, isFinal: true))
                    }
                }) else {
                    completion(AnimationCacheItemResult(item: nil, isFinal: true))
                    return EmptyDisposable
                }
                
                let fetchDisposable = fetch(AnimationCacheFetchOptions(size: size, writer: writer, firstFrameOnly: true))
                return fetchDisposable
            } else {
                completion(AnimationCacheItemResult(item: nil, isFinal: true))
                return EmptyDisposable
            }
        }
    }
    
    private let queue: Queue
    private let basePath: String
    private let impl: QueueLocalObject<Impl>
    private let allocateTempFile: () -> String
    private let updateStorageStats: (String, Int64) -> Void
    
    public init(basePath: String, allocateTempFile: @escaping () -> String, updateStorageStats: @escaping (String, Int64) -> Void) {
        let queue = Queue()
        self.queue = queue
        self.basePath = basePath
        self.allocateTempFile = allocateTempFile
        self.updateStorageStats = updateStorageStats
        self.impl = QueueLocalObject(queue: queue, generate: {
            return Impl(queue: queue, basePath: basePath, allocateTempFile: allocateTempFile, updateStorageStats: updateStorageStats)
        })
    }
    
    public func get(sourceId: String, size: CGSize, fetch: @escaping (AnimationCacheFetchOptions) -> Disposable) -> Signal<AnimationCacheItemResult, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                disposable.set(impl.get(sourceId: sourceId, size: size, fetch: fetch, updateResult: { result in
                    subscriber.putNext(result)
                    if result.isFinal {
                        subscriber.putCompletion()
                    }
                }))
            }
            
            return disposable
        }
        |> runOn(self.queue)
    }
    
    public func getFirstFrameSynchronously(sourceId: String, size: CGSize) -> AnimationCacheItem? {
        return Impl.getFirstFrameSynchronously(basePath: self.basePath, sourceId: sourceId, size: size, allocateTempFile: self.allocateTempFile, updateStorageStats: self.updateStorageStats)
    }
    
    public func getFirstFrame(queue: Queue, sourceId: String, size: CGSize, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (AnimationCacheItemResult) -> Void) -> Disposable {
        let disposable = MetaDisposable()
        
        let basePath = self.basePath
        let allocateTempFile = self.allocateTempFile
        let updateStorageStats = self.updateStorageStats
        queue.async {
            disposable.set(Impl.getFirstFrame(queue: queue, basePath: basePath, sourceId: sourceId, size: size, allocateTempFile: allocateTempFile, updateStorageStats: updateStorageStats, fetch: fetch, completion: completion))
        }
        
        return disposable
    }
}
