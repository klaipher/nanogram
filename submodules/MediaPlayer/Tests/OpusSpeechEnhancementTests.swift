import Foundation
import CoreMedia
import XCTest
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

final class OpusSpeechEnhancementTests: XCTestCase {
    override func tearDown() {
        OpusSpeechEnhancement.isEnabled = false
        super.tearDown()
    }

    // MARK: option selection (pure logic)

    func testSwitchOffNeverEnhances() {
        XCTAssertNil(OpusSpeechEnhancement.decoderOptions(enabled: false, isPlayback: true))
        XCTAssertNil(OpusSpeechEnhancement.decoderOptions(enabled: false, isPlayback: false))
    }

    func testPlaybackWithTheSwitchOnGetsNoLaceAndBandwidthExtension() {
        let options = OpusSpeechEnhancement.decoderOptions(enabled: true, isPlayback: true)
        XCTAssertEqual(options, OpusSpeechEnhancement.DecoderOptions(complexity: 7, bandwidthExtension: true))
    }

    func testTranscriptionAndOtherNonPlaybackOpensStayAtTheStockDecoder() {
        XCTAssertNil(OpusSpeechEnhancement.decoderOptions(enabled: true, isPlayback: false))
    }

    func testTheSwitchDefaultsToOffAndIsReadable() {
        XCTAssertFalse(OpusSpeechEnhancement.isEnabled)
        OpusSpeechEnhancement.isEnabled = true
        XCTAssertTrue(OpusSpeechEnhancement.isEnabled)
    }

    // MARK: decoding (needs the OSCE libopus built by //third-party/opus)

    private func decodePlaybackPCM(name: String, enabled: Bool) throws -> [Int16] {
        let path = try MediaTestSupport.resourcePath(name, "opus")
        OpusSpeechEnhancement.isEnabled = enabled
        guard let reader = FFMpegFileReader(source: .file(path), useHardwareAcceleration: false, selectedStream: .mediaType(.audio), seek: nil, maxReadablePts: nil) else {
            XCTFail("cannot open \(name).opus")
            return []
        }
        var samples: [Int16] = []
        loop: while true {
            switch reader.readFrame() {
            case let .frame(frame):
                guard let blockBuffer = CMSampleBufferGetDataBuffer(frame.sampleBuffer) else {
                    XCTFail("no data")
                    break loop
                }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var chunk = [Int16](repeating: 0, count: length / 2)
                chunk.withUnsafeMutableBytes { buffer in
                    _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
                }
                samples.append(contentsOf: chunk)
            case .endOfStream, .error, .waitingForMoreData:
                break loop
            }
        }
        return samples
    }

    func testEnhancedPlaybackDiffersFromTheStockDecoderAndKeepsTheLength() throws {
        for name in ["voice_hybrid_30k", "voice_silk_wb"] {
            let stock = try decodePlaybackPCM(name: name, enabled: false)
            let enhanced = try decodePlaybackPCM(name: name, enabled: true)
            XCTAssertGreaterThan(stock.count, 100_000, name)
            XCTAssertEqual(stock.count, enhanced.count, "\(name): enhancement must not change the sample count (pre-skip is honoured)")
            XCTAssertNotEqual(stock, enhanced, "\(name): the NoLACE decode must differ from the stock decode")
            XCTAssertFalse(enhanced.contains(where: { $0 == Int16.min }), "\(name): no hard clipping")
        }
    }

    func testStockPlaybackIsRepeatable() throws {
        let first = try decodePlaybackPCM(name: "voice_hybrid_30k", enabled: false)
        let second = try decodePlaybackPCM(name: "voice_hybrid_30k", enabled: false)
        XCTAssertEqual(first, second)
    }

    func testTranscriptionPathIsNotEnhancedEvenWithTheSwitchOn() throws {
        let path = try MediaTestSupport.resourcePath("voice_hybrid_30k", "opus")
        OpusSpeechEnhancement.isEnabled = false
        let stock = SoftwareAudioSource(path: path)
        var stockBytes = Data()
        while let buffer = stock.readSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                var data = Data(count: CMBlockBufferGetDataLength(block))
                data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                stockBytes.append(data)
            }
        }
        OpusSpeechEnhancement.isEnabled = true
        let switched = SoftwareAudioSource(path: path)
        var switchedBytes = Data()
        while let buffer = switched.readSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                var data = Data(count: CMBlockBufferGetDataLength(block))
                data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                switchedBytes.append(data)
            }
        }
        XCTAssertFalse(stockBytes.isEmpty)
        XCTAssertEqual(stockBytes, switchedBytes, "convertOpusToAAC's source (isPlayback false) must decode identically with the switch on")
    }
}
