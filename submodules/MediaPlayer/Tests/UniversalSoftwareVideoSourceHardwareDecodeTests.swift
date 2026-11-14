import XCTest
import FFMpegBinding
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

final class UniversalSoftwareVideoSourceHardwareDecodeTests: XCTestCase {
    func testStaysSoftwareWhenTheExperimentIsOff() {
        XCTAssertFalse(UniversalSoftwareVideoSource.shouldUseHardwareDecode(enabled: false, codecId: FFMpegCodecIdHEVC, width: 3840, height: 2160))
    }

    func testLargeH264AndHEVCUseHardware() {
        XCTAssertTrue(UniversalSoftwareVideoSource.shouldUseHardwareDecode(enabled: true, codecId: FFMpegCodecIdHEVC, width: 3840, height: 2160))
        XCTAssertTrue(UniversalSoftwareVideoSource.shouldUseHardwareDecode(enabled: true, codecId: FFMpegCodecIdH264, width: 1920, height: 1080))
        XCTAssertTrue(UniversalSoftwareVideoSource.shouldUseHardwareDecode(enabled: true, codecId: FFMpegCodecIdH264, width: 1080, height: 1920))
    }

    func testSmallClipsStaySoftware() {
        XCTAssertFalse(UniversalSoftwareVideoSource.shouldUseHardwareDecode(enabled: true, codecId: FFMpegCodecIdH264, width: 1280, height: 720))
    }

    func testOtherCodecsStaySoftware() {
        XCTAssertFalse(UniversalSoftwareVideoSource.shouldUseHardwareDecode(enabled: true, codecId: FFMpegCodecIdAV1, width: 3840, height: 2160))
        XCTAssertFalse(UniversalSoftwareVideoSource.shouldUseHardwareDecode(enabled: true, codecId: FFMpegCodecIdVP9, width: 3840, height: 2160))
    }
}
