import XCTest
import CoreMedia
import FFMpegBinding
@testable import TelegramMediaPlayer

final class MediaPlayerAudioFormatTests: XCTestCase {
    func testPlaybackRunsAtTheMacOutputRate() {
        XCTAssertEqual(MediaPlayerAudioFormat.sampleRate, 48000)
        XCTAssertEqual(MediaPlayerAudioFormat.channelCount, 2)
    }

    func testDecoderYieldsPlaybackRateSamplesPerMediaSecond() throws {
        let path = try MediaTestSupport.resourcePath("aac_h264_bframes", "mp4")
        let context = FFMpegAVFormatContext()
        XCTAssertTrue(context.openInput(withDirectFilePath: path))
        XCTAssertTrue(context.findStreamInfo())
        let index = try XCTUnwrap(context.streamIndices(for: FFMpegAVFormatStreamTypeAudio).first).int32Value
        let codec = try XCTUnwrap(FFMpegAVCodec.find(forId: context.codecId(atStreamIndex: index), preferHardwareAccelerationCapable: false))
        let codecContext = FFMpegAVCodecContext(codec: codec)
        XCTAssertTrue(context.codecParams(atStreamIndex: index, to: codecContext))
        XCTAssertTrue(codecContext.open())
        let decoder = FFMpegMediaFrameSourceContextHelpers.makeAudioDecoder(codecContext: codecContext)
        let timebase = context.fpsAndTimebase(forStreamIndex: index, defaultTimeBase: CMTimeMake(value: 1, timescale: 40000)).timebase
        var samples = 0
        var first: CMTime?
        var last = CMTime.zero
        let packet = FFMpegPacket()
        while context.readFrame(into: packet) {
            if packet.streamIndex != index {
                continue
            }
            let pts = CMTimeMake(value: packet.pts, timescale: timebase.timescale)
            let frame = MediaTrackDecodableFrame(type: .audio, packet: packet, pts: pts, dts: pts, duration: CMTimeMake(value: packet.duration, timescale: timebase.timescale))
            XCTAssertTrue(decoder.send(frame: frame))
            while let decoded = decoder.decode() {
                let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(decoded.sampleBuffer))
                let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
                XCTAssertEqual(asbd.mSampleRate, 48000)
                XCTAssertEqual(asbd.mChannelsPerFrame, 2)
                samples += CMSampleBufferGetNumSamples(decoded.sampleBuffer)
                first = first ?? decoded.position
                last = CMTimeAdd(decoded.position, CMSampleBufferGetDuration(decoded.sampleBuffer))
            }
        }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(last, try XCTUnwrap(first)))
        XCTAssertGreaterThan(seconds, 0.5)
        XCTAssertEqual(Double(samples) / seconds, 48000, accuracy: 48000 * 0.02)
    }
}
