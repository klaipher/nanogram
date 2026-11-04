import Foundation
import CoreMedia
import XCTest
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

private func writeWav(channels: [Double], sampleRate: Int, seconds: Double) -> String {
    let frameCount = Int(Double(sampleRate) * seconds)
    var pcm = Data(capacity: frameCount * channels.count * 2)
    for i in 0 ..< frameCount {
        let t = Double(i) / Double(sampleRate)
        for frequency in channels {
            var sample = Int16(sin(2.0 * Double.pi * frequency * t) * 12000.0).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
    }
    func u32(_ value: Int) -> Data {
        var v = UInt32(value).littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
    func u16(_ value: Int) -> Data {
        var v = UInt16(value).littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
    var wav = Data()
    wav.append("RIFF".data(using: .ascii)!)
    wav.append(u32(36 + pcm.count))
    wav.append("WAVEfmt ".data(using: .ascii)!)
    wav.append(u32(16))
    wav.append(u16(1))
    wav.append(u16(channels.count))
    wav.append(u32(sampleRate))
    wav.append(u32(sampleRate * channels.count * 2))
    wav.append(u16(channels.count * 2))
    wav.append(u16(16))
    wav.append("data".data(using: .ascii)!)
    wav.append(u32(pcm.count))
    wav.append(pcm)
    let path = NSTemporaryDirectory() + "stereo_reader_\(UUID().uuidString).wav"
    try! wav.write(to: URL(fileURLWithPath: path))
    return path
}

private struct DecodedAudio {
    var channelsPerFrame: UInt32 = 0
    var layoutTag: AudioChannelLayoutTag = 0
    var sampleCountMismatch = false
    var interleaved: [Int16] = []
}

private func decodeAudio(path: String) -> DecodedAudio? {
    guard let reader = FFMpegFileReader(source: .file(path), useHardwareAcceleration: false, selectedStream: .mediaType(.audio), seek: nil, maxReadablePts: nil) else {
        return nil
    }
    var result = DecodedAudio()
    loop: while true {
        switch reader.readFrame() {
        case let .frame(frame):
            let sampleBuffer = frame.sampleBuffer
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                return nil
            }
            result.channelsPerFrame = asbd.mChannelsPerFrame
            var layoutSize = 0
            if let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &layoutSize) {
                result.layoutTag = layout.pointee.mChannelLayoutTag
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                return nil
            }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            if CMSampleBufferGetNumSamples(sampleBuffer) * Int(asbd.mBytesPerFrame) != length {
                result.sampleCountMismatch = true
            }
            var bytes = [Int16](repeating: 0, count: length / 2)
            bytes.withUnsafeMutableBytes { buffer in
                _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }
            result.interleaved.append(contentsOf: bytes)
        case .endOfStream, .error:
            break loop
        case .waitingForMoreData:
            break loop
        }
    }
    return result
}

private func power(_ samples: [Double], frequency: Double, sampleRate: Double) -> Double {
    let coefficient = 2.0 * cos(2.0 * Double.pi * frequency / sampleRate)
    var s1 = 0.0
    var s2 = 0.0
    for sample in samples {
        let s0 = sample + coefficient * s1 - s2
        s2 = s1
        s1 = s0
    }
    return s1 * s1 + s2 * s2 - coefficient * s1 * s2
}

final class FFMpegFileReaderStereoAudioTests: XCTestCase {
    func testStereoSourceDecodesToStereo() throws {
        let path = writeWav(channels: [440.0, 880.0], sampleRate: 48000, seconds: 1.0)
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }
        let decoded = try XCTUnwrap(decodeAudio(path: path))
        XCTAssertEqual(decoded.channelsPerFrame, 2)
        XCTAssertEqual(decoded.layoutTag, kAudioChannelLayoutTag_Stereo)
        XCTAssertFalse(decoded.sampleCountMismatch, "numSamples × bytesPerFrame must equal the data length")
        guard decoded.channelsPerFrame == 2 else {
            return
        }
        let left = stride(from: 0, to: decoded.interleaved.count, by: 2).map { Double(decoded.interleaved[$0]) }
        let right = stride(from: 1, to: decoded.interleaved.count, by: 2).map { Double(decoded.interleaved[$0]) }
        XCTAssertGreaterThan(left.count, 40000)
        XCTAssertGreaterThan(power(left, frequency: 440.0, sampleRate: 48000.0), 100.0 * power(left, frequency: 880.0, sampleRate: 48000.0))
        XCTAssertGreaterThan(power(right, frequency: 880.0, sampleRate: 48000.0), 100.0 * power(right, frequency: 440.0, sampleRate: 48000.0))
    }

    func testMonoSourceStaysMono() throws {
        let path = writeWav(channels: [440.0], sampleRate: 48000, seconds: 0.5)
        defer {
            try? FileManager.default.removeItem(atPath: path)
        }
        let decoded = try XCTUnwrap(decodeAudio(path: path))
        XCTAssertEqual(decoded.channelsPerFrame, 1)
        XCTAssertEqual(decoded.layoutTag, kAudioChannelLayoutTag_Mono)
        XCTAssertFalse(decoded.sampleCountMismatch)
        XCTAssertGreaterThan(decoded.interleaved.count, 20000)
    }
}
