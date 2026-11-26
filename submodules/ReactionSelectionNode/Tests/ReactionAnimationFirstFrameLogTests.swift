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

    // The effect is created at once but only allowed to play 0.15 s later (upstream's choreography). All 30
    // effect lines in the 13.2 (202611232311) logs read 171-203 ms "the wait was rendering"; the rendering was
    // the 21-53 ms after that delay. The line names the delay apart and blames rendering only for the rest.
    func testFirstFrameLineSeparatesThePlannedDelayFromRendering() {
        let local = ReactionAnimationFirstFrameLog(kind: .effect, reaction: "👍", fileIsLocal: true, requestTime: 100.0)
        XCTAssertEqual(local.firstFrameLine(now: 100.177, playStartTime: 100.15), "reaction 👍: effect first frame after 177 ms (150 ms of it held back on purpose before playing; file was on the device: the other 27 ms was rendering)")

        let missing = ReactionAnimationFirstFrameLog(kind: .effect, reaction: "👍", fileIsLocal: false, requestTime: 100.0)
        XCTAssertEqual(missing.firstFrameLine(now: 101.0, playStartTime: 100.15), "reaction 👍: effect first frame after 1000 ms (150 ms of it held back on purpose before playing; file was not on the device: the wait includes its download)")
    }

    func testWithoutAPlayStartTheLineIsUnchanged() {
        let log = ReactionAnimationFirstFrameLog(kind: .largerAnimation, reaction: "👍", fileIsLocal: true, requestTime: 100.0)
        XCTAssertEqual(log.firstFrameLine(now: 100.177, playStartTime: nil), log.firstFrameLine(now: 100.177))
        XCTAssertEqual(log.firstFrameLine(now: 100.177), "reaction 👍: larger animation first frame after 177 ms (file was on the device: the wait was rendering)")
    }

    func testAPlayStartOutsideTheWaitReportsNoNegativePart() {
        let log = ReactionAnimationFirstFrameLog(kind: .effect, reaction: "👍", fileIsLocal: true, requestTime: 100.0)
        // Allowed to play after the first frame was reported: the whole wait was the delay, nothing was rendering.
        XCTAssertEqual(log.firstFrameLine(now: 100.1, playStartTime: 100.15), "reaction 👍: effect first frame after 100 ms (100 ms of it held back on purpose before playing; file was on the device: the other 0 ms was rendering)")
        // Allowed to play before it was asked for: no delay, all of it was rendering.
        XCTAssertEqual(log.firstFrameLine(now: 100.03, playStartTime: 99.0), "reaction 👍: effect first frame after 30 ms (0 ms of it held back on purpose before playing; file was on the device: the other 30 ms was rendering)")
        // A clock going backwards past the request.
        XCTAssertEqual(log.firstFrameLine(now: 99.0, playStartTime: 100.15), "reaction 👍: effect first frame after 0 ms (0 ms of it held back on purpose before playing; file was on the device: the other 0 ms was rendering)")
    }

    func testAClockGoingBackwardsReportsNoNegativeWait() {
        let log = ReactionAnimationFirstFrameLog(kind: .effect, reaction: "👍", fileIsLocal: true, requestTime: 100.0)
        XCTAssertTrue(log.firstFrameLine(now: 99.0).contains("after 0 ms"))
    }
}
