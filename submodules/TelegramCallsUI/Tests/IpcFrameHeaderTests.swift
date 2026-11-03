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

    func testDetectorSkipsAFrameItAlreadyHas() {
        var detector = IpcFrameChangeDetector()
        XCTAssertTrue(detector.shouldDeserialize(counter: 5))
        XCTAssertFalse(detector.shouldDeserialize(counter: 5))
        XCTAssertFalse(detector.shouldDeserialize(counter: 5))
        XCTAssertTrue(detector.shouldDeserialize(counter: 6))
        // After a wrap the counter goes down; it is still a new frame.
        XCTAssertTrue(detector.shouldDeserialize(counter: 1))
    }

    func testDetectorAlwaysConvertsLegacyFrames() {
        var detector = IpcFrameChangeDetector()
        XCTAssertTrue(detector.shouldDeserialize(counter: 0))
        XCTAssertTrue(detector.shouldDeserialize(counter: 0))
    }
}
