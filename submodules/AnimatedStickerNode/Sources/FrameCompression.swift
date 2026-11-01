import Foundation
import Compression
import YuvConversion

// Per-frame sticker caches. LZ4 instead of LZFSE: measured on real sticker frames,
// encoding 14x and decoding 9x faster for 24% more bytes. Every displayed frame of a
// looping sticker is decoded again, so decode speed matters most. The cache file names
// carry a version, so older builds never read LZ4 frames.
let stickerFrameCompressionAlgorithm: compression_algorithm = COMPRESSION_LZ4

// Decodes a frame straight into a new buffer. Nil unless exactly `decodedLength` bytes
// come out, so a damaged frame is never shown as a short buffer.
func decompressFrame(bytes: UnsafePointer<UInt8>, length: Int, decodedLength: Int, scratch: UnsafeMutableRawPointer?) -> Data? {
    if length <= 0 || decodedLength <= 0 {
        return nil
    }
    let buffer = malloc(decodedLength)!.assumingMemoryBound(to: UInt8.self)
    let resultLength = compression_decode_buffer(buffer, decodedLength, bytes, length, scratch, stickerFrameCompressionAlgorithm)
    if resultLength != decodedLength {
        free(buffer)
        return nil
    }
    return Data(bytesNoCopy: buffer, count: decodedLength, deallocator: .free)
}

func compressFrame(width: Int, height: Int, rgbData: Data, unpremultiply: Bool) -> Data? {
    let bytesPerRow = rgbData.count / height
    
    let yuvaPixelsPerAlphaRow = (Int(width) + 1) & (~1)
    assert(yuvaPixelsPerAlphaRow % 2 == 0)
    
    let yuvaLength = Int(width) * Int(height) * 2 + yuvaPixelsPerAlphaRow * Int(height) / 2
    let yuvaFrameData = malloc(yuvaLength)!
    defer {
        free(yuvaFrameData)
    }
    memset(yuvaFrameData, 0, yuvaLength)
    
    var compressedFrameData = Data(count: yuvaLength)
    let compressedFrameDataLength = compressedFrameData.count
    
    let scratchData = malloc(compression_encode_scratch_buffer_size(stickerFrameCompressionAlgorithm))!
    defer {
        free(scratchData)
    }
    
    var rgbData = rgbData
    rgbData.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Void in
        if let baseAddress = buffer.baseAddress {
            encodeRGBAToYUVA(yuvaFrameData.assumingMemoryBound(to: UInt8.self), baseAddress.assumingMemoryBound(to: UInt8.self), Int32(width), Int32(height), Int32(bytesPerRow), true, unpremultiply)
        }
    }
    
    var maybeResultSize: Int?
    
    compressedFrameData.withUnsafeMutableBytes { buffer -> Void in
        guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return
        }
        let length = compression_encode_buffer(bytes, compressedFrameDataLength, yuvaFrameData.assumingMemoryBound(to: UInt8.self), yuvaLength, scratchData, stickerFrameCompressionAlgorithm)
        maybeResultSize = length
    }
    
    // 0 means the frame did not fit; it is then not cached.
    guard let resultSize = maybeResultSize, resultSize > 0 else {
        return nil
    }
    compressedFrameData.count = resultSize
    return compressedFrameData
}

func compressFrame(width: Int, height: Int, yuvaData: Data) -> Data? {
    let yuvaLength = yuvaData.count
    
    var compressedFrameData = Data(count: yuvaLength)
    let compressedFrameDataLength = compressedFrameData.count
    
    let scratchData = malloc(compression_encode_scratch_buffer_size(stickerFrameCompressionAlgorithm))!
    defer {
        free(scratchData)
    }

    var maybeResultSize: Int?
    
    yuvaData.withUnsafeBytes { yuvaBuffer -> Void in
        if let yuvaFrameData = yuvaBuffer.baseAddress {
            compressedFrameData.withUnsafeMutableBytes { buffer -> Void in
                guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                let length = compression_encode_buffer(bytes, compressedFrameDataLength, yuvaFrameData.assumingMemoryBound(to: UInt8.self), yuvaLength, scratchData, stickerFrameCompressionAlgorithm)
                maybeResultSize = length
            }
        }
    }
    
    // 0 means the frame did not fit; it is then not cached.
    guard let resultSize = maybeResultSize, resultSize > 0 else {
        return nil
    }
    compressedFrameData.count = resultSize
    return compressedFrameData
}
