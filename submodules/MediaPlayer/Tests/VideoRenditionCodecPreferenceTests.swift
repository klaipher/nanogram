import XCTest
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

final class VideoRenditionCodecPreferenceTests: XCTestCase {
    func testHardwareAv1KeepsAv1AsBefore() {
        // An AV1 rendition stays; anything else is replaced by the next one (the last one wins).
        XCTAssertFalse(VideoRenditionCodecPreference.shouldReplace(currentCodec: "av01", candidateCodec: "h264", isHardwareAv1Supported: true))
        XCTAssertFalse(VideoRenditionCodecPreference.shouldReplace(currentCodec: "av1", candidateCodec: "av01", isHardwareAv1Supported: true))
        XCTAssertTrue(VideoRenditionCodecPreference.shouldReplace(currentCodec: "h264", candidateCodec: "av01", isHardwareAv1Supported: true))
        XCTAssertTrue(VideoRenditionCodecPreference.shouldReplace(currentCodec: "h264", candidateCodec: "hevc", isHardwareAv1Supported: true))
    }

    func testSoftwareOnlyAv1IsTheLastResort() {
        XCTAssertTrue(VideoRenditionCodecPreference.shouldReplace(currentCodec: "av01", candidateCodec: "h264", isHardwareAv1Supported: false), "H.264 replaces software AV1")
        XCTAssertTrue(VideoRenditionCodecPreference.shouldReplace(currentCodec: "av1", candidateCodec: "hevc", isHardwareAv1Supported: false))
        XCTAssertFalse(VideoRenditionCodecPreference.shouldReplace(currentCodec: "h264", candidateCodec: "av01", isHardwareAv1Supported: false), "software AV1 does not replace H.264")
        XCTAssertFalse(VideoRenditionCodecPreference.shouldReplace(currentCodec: "av01", candidateCodec: "av1", isHardwareAv1Supported: false))
        XCTAssertTrue(VideoRenditionCodecPreference.shouldReplace(currentCodec: "h264", candidateCodec: "hevc", isHardwareAv1Supported: false))
    }

    func testBothSpellingsOfAv1AreRecognised() {
        XCTAssertTrue(VideoRenditionCodecPreference.isAv1("av1"))
        XCTAssertTrue(VideoRenditionCodecPreference.isAv1("av01"))
        XCTAssertFalse(VideoRenditionCodecPreference.isAv1("avc1"))
        XCTAssertFalse(VideoRenditionCodecPreference.isAv1(nil))
    }
}
