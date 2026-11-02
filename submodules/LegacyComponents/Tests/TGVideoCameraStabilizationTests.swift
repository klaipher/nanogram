import XCTest
import AVFoundation
import LegacyComponents

/// The legacy round-video pipeline (`TGVideoCameraPipeline`, story-reply circles) asked for cinematic-extended
/// stabilization, which Apple documents as adding much more preview latency and memory than standard. It now
/// makes CameraNeo's choice: standard where supported, otherwise off.
final class TGVideoCameraStabilizationTests: XCTestCase {
    func testStandardWhereSupported() {
        XCTAssertEqual(TGVideoMessageStabilizationMode(true, true), .standard)
    }

    func testOffWhenTheFormatHasNoStandardStabilization() {
        XCTAssertEqual(TGVideoMessageStabilizationMode(true, false), .off)
    }

    func testOffWhenTheConnectionCannotStabilize() {
        XCTAssertEqual(TGVideoMessageStabilizationMode(false, true), .off)
        XCTAssertEqual(TGVideoMessageStabilizationMode(false, false), .off)
    }
}
