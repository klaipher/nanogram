import Foundation
import XCTest
@testable import ReactionSelectionNode

// A sent reaction's larger animation and its effect both drew nothing for about 2 s in the owner's
// recording (13.1.2, 202611031553), and the effect is only waited for when its file is on the device.
// The log line for each must say whether its file was on the device when it was asked for: a long
// wait with the file there is the renderer's, without it the download's.
final class ReactionAnimationFirstFrameLogTests: XCTestCase {
    func testRequestLineSaysWhetherTheFileIsOnTheDevice() {
        let local = ReactionAnimationFirstFrameLog(kind: .largerAnimation, reaction: "👍", fileIsLocal: true, requestTime: 100.0)
        XCTAssertEqual(local.requestedLine, "reaction 👍: larger animation requested, file on the device")

        let missing = ReactionAnimationFirstFrameLog(kind: .effect, reaction: "💅", fileIsLocal: false, requestTime: 100.0)
        XCTAssertEqual(missing.requestedLine, "reaction 💅: effect requested, file not on the device yet")
    }

    func testFirstFrameLineNamesTheWaitAndItsCause() {
        let local = ReactionAnimationFirstFrameLog(kind: .effect, reaction: "👍", fileIsLocal: true, requestTime: 100.0)
        XCTAssertEqual(local.firstFrameLine(now: 101.2345), "reaction 👍: effect first frame after 1234 ms (file was on the device: the wait was rendering)")

        let missing = ReactionAnimationFirstFrameLog(kind: .largerAnimation, reaction: "👍", fileIsLocal: false, requestTime: 100.0)
        XCTAssertEqual(missing.firstFrameLine(now: 100.05), "reaction 👍: larger animation first frame after 50 ms (file was not on the device: the wait includes its download)")
    }

    func testAClockGoingBackwardsReportsNoNegativeWait() {
        let log = ReactionAnimationFirstFrameLog(kind: .effect, reaction: "👍", fileIsLocal: true, requestTime: 100.0)
        XCTAssertTrue(log.firstFrameLine(now: 99.0).contains("after 0 ms"))
    }
}
