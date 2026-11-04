import XCTest
import FFMpegBinding
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

final class FFMpegSoftwareDecodeThreadsTests: XCTestCase {
    func testLargeAV1DecodesOnSeveralThreads() {
        XCTAssertEqual(FFMpegSoftwareDecodeThreads.threadCount(codecId: FFMpegCodecIdAV1, width: 1920, height: 1080, processorCount: 10), 8)
        XCTAssertEqual(FFMpegSoftwareDecodeThreads.threadCount(codecId: FFMpegCodecIdAV1, width: 1280, height: 720, processorCount: 4), 4)
        XCTAssertEqual(FFMpegSoftwareDecodeThreads.threadCount(codecId: FFMpegCodecIdAV1, width: 3840, height: 2160, processorCount: 0), 1)
    }

    func testSmallClipsAndOtherCodecsStaySingleThreaded() {
        XCTAssertEqual(FFMpegSoftwareDecodeThreads.threadCount(codecId: FFMpegCodecIdAV1, width: 640, height: 360, processorCount: 10), 1)
        XCTAssertEqual(FFMpegSoftwareDecodeThreads.threadCount(codecId: FFMpegCodecIdH264, width: 1920, height: 1080, processorCount: 10), 1)
        XCTAssertEqual(FFMpegSoftwareDecodeThreads.threadCount(codecId: FFMpegCodecIdHEVC, width: 1920, height: 1080, processorCount: 10), 1)
        XCTAssertEqual(FFMpegSoftwareDecodeThreads.threadCount(codecId: FFMpegCodecIdVP9, width: 512, height: 512, processorCount: 10), 1)
    }

    func testCodecContextTakesTheThreadCount() throws {
        let codec = try XCTUnwrap(FFMpegAVCodec.find(forId: FFMpegCodecIdAV1, preferHardwareAccelerationCapable: false))
        let context = FFMpegAVCodecContext(codec: codec)
        XCTAssertEqual(context.threadCount(), 1)
        FFMpegSoftwareDecodeThreads.apply(to: context, codecId: FFMpegCodecIdAV1, width: 1920, height: 1080, processorCount: 6)
        XCTAssertEqual(context.threadCount(), 6)
        XCTAssertTrue(context.open())
    }
}
