import Foundation
import XCTest
import TelegramVoip

/// The screen-share extension and the app share one memory-mapped frame. Its first four bytes held the
/// image orientation (1...8); the upper 24 bits now carry a frame counter, so the app can tell a new
/// frame from the one it already copied and stops converting the same frame 30 times a second.
final class IpcFrameHeaderTests: XCTestCase {
    func testOrientationSurvivesAnyCounter() {
        for orientation: UInt32 in 1 ... 8 {
            for counter: UInt32 in [0, 1, 2, 0xFFFF, 0xFFFFFF] {
                let packed = IpcFrameHeader.pack(orientation: orientation, counter: counter)
                let unpacked = IpcFrameHeader.unpack(packed)
                XCTAssertEqual(unpacked.orientation, orientation)
                XCTAssertEqual(unpacked.counter, counter)
            }
        }
    }

    /// A header written before the counter existed is a bare orientation.
    func testLegacyHeaderHasCounterZero() {
        for orientation: UInt32 in 1 ... 8 {
            let unpacked = IpcFrameHeader.unpack(Int32(orientation))
            XCTAssertEqual(unpacked.orientation, orientation)
            XCTAssertEqual(unpacked.counter, 0)
        }
    }

    func testCounterNeverReturnsToZero() {
        XCTAssertEqual(IpcFrameHeader.nextCounter(0), 1)
        XCTAssertEqual(IpcFrameHeader.nextCounter(1), 2)
        XCTAssertEqual(IpcFrameHeader.nextCounter(0xFFFFFE), 0xFFFFFF)
        XCTAssertEqual(IpcFrameHeader.nextCounter(0xFFFFFF), 1)
    }

    func testDetectorConvertsOnlyANewFrame() {
        var detector = IpcFrameChangeDetector()
        XCTAssertEqual(detector.action(counter: 5, now: 0.0), .convert)
        XCTAssertEqual(detector.action(counter: 5, now: 0.01), .skip)
        XCTAssertEqual(detector.action(counter: 6, now: 0.02), .convert)
        // After a wrap the counter goes down; it is still a new frame.
        XCTAssertEqual(detector.action(counter: 1, now: 0.03), .convert)
    }

    /// ReplayKit delivers a frame only when the screen changes. A still screen must keep reaching the
    /// encoder, or a viewer who joins (or a peer that asks for a keyframe) gets nothing until the screen moves.
    func testStillScreenResendsTheLastFrameWithoutConverting() {
        var detector = IpcFrameChangeDetector()
        XCTAssertEqual(detector.action(counter: 5, now: 0.0), .convert)
        XCTAssertEqual(detector.action(counter: 5, now: 0.033), .skip)
        XCTAssertEqual(detector.action(counter: 5, now: 0.066), .skip)
        XCTAssertEqual(detector.action(counter: 5, now: IpcFrameChangeDetector.resendInterval + 0.001), .resend)
        // The resend restarts the interval.
        XCTAssertEqual(detector.action(counter: 5, now: IpcFrameChangeDetector.resendInterval + 0.034), .skip)
        XCTAssertEqual(detector.action(counter: 5, now: 2 * IpcFrameChangeDetector.resendInterval + 0.002), .resend)
    }

    func testNewFrameRestartsTheResendInterval() {
        var detector = IpcFrameChangeDetector()
        XCTAssertEqual(detector.action(counter: 5, now: 0.0), .convert)
        XCTAssertEqual(detector.action(counter: 6, now: 0.09), .convert)
        XCTAssertEqual(detector.action(counter: 6, now: 0.09 + IpcFrameChangeDetector.resendInterval - 0.01), .skip)
    }

    func testDetectorAlwaysConvertsLegacyFrames() {
        var detector = IpcFrameChangeDetector()
        XCTAssertEqual(detector.action(counter: 0, now: 0.0), .convert)
        XCTAssertEqual(detector.action(counter: 0, now: 0.01), .convert)
    }
}
