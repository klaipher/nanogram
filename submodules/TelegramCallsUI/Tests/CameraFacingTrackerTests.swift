import XCTest
@testable import TelegramCallsUI

final class CameraFacingTrackerTests: XCTestCase {
    func testFlipSwitchesBetweenTheCameras() {
        var tracker = CameraFacingTracker()
        tracker.cameraStarted()
        XCTAssertEqual(tracker.flip(), false)
        XCTAssertEqual(tracker.flip(), true)
    }

    func testFlipWithoutACameraChangesNothing() {
        var tracker = CameraFacingTracker()
        XCTAssertNil(tracker.flip())
        tracker.cameraStarted()
        XCTAssertEqual(tracker.flip(), false, "the first real flip goes to the back camera")
    }

    /// Flip to the back camera, switch the camera off, switch it on again: the new capturer is on the front camera, so
    /// the first flip must go to the back camera. It used to ask for the front camera it was already on.
    func testANewCapturerAfterTheCameraWasOffStartsOnTheFront() {
        var tracker = CameraFacingTracker()
        tracker.cameraStarted()
        XCTAssertEqual(tracker.flip(), false)
        tracker.cameraStopped()
        XCTAssertNil(tracker.flip())
        tracker.cameraStarted()
        XCTAssertEqual(tracker.flip(), false)
    }

    /// A capturer handed over already on the back camera (the video chat screen, a 1:1 call turning into a conference).
    func testACapturerHandedOverOnTheBackCameraFlipsToTheFront() {
        var tracker = CameraFacingTracker()
        tracker.cameraStarted(isFront: false)
        XCTAssertEqual(tracker.flip(), true)
    }
}
