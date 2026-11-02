import XCTest
import AVFoundation
@testable import CameraNeo

/// Pins where the round-video preview connection is switched on and off.
///
/// The circle screen disables the preview on pause and enables it on resume, on the main thread. The change
/// is a capture graph change that AVFoundation serializes with the session's `startRunning()`/`stopRunning()`,
/// which run on CameraNeo's session queue and block for as long as they take. So the preview view hands the
/// change to that queue (in order, ahead of the start or stop the screen queues right after it) instead of
/// making it on the calling thread.
final class CameraPreviewConnectionTests: XCTestCase {
    func testWithAQueueTheChangeRunsLaterOnThatQueueInOrder() {
        let queue = DispatchQueue(label: "CameraPreviewConnectionTests.session")
        queue.suspend()

        var applied: [Bool] = []
        for value in [false, true, false] {
            CameraPreviewView.perform(on: queue) {
                dispatchPrecondition(condition: .onQueue(queue))
                applied.append(value)
            }
        }
        // A synchronous hop onto the (stuck) queue would never have returned; nothing ran on this thread either.
        XCTAssertEqual(applied, [])

        let drained = self.expectation(description: "queue drained")
        queue.async {
            drained.fulfill()
        }
        queue.resume()
        self.wait(for: [drained], timeout: 2.0)
        queue.sync {
            XCTAssertEqual(applied, [false, true, false])
        }
    }

    func testWithoutAQueueTheChangeIsImmediate() {
        var applied: [Bool] = []
        CameraPreviewView.perform(on: nil) {
            applied.append(true)
        }
        XCTAssertEqual(applied, [true])
    }

    func testSettingIsEnabledDoesNotWaitForABusySessionQueue() {
        let view = CameraPreviewView(frame: CGRect(x: 0.0, y: 0.0, width: 100.0, height: 100.0), main: true, roundVideo: true)
        let session = AVCaptureSession()
        let queue = DispatchQueue(label: "CameraPreviewConnectionTests.busySession")
        view.connectionQueue = queue
        view.setSession(session, automaticallyConnect: true)

        // The session queue is stuck (as in a long startRunning()/stopRunning()).
        queue.suspend()
        let start = CACurrentMediaTime()
        view.isEnabled = false
        view.isEnabled = true
        XCTAssertLessThan(CACurrentMediaTime() - start, 0.5)
        XCTAssertTrue(view.isEnabled)

        let drained = self.expectation(description: "queue drained")
        queue.async {
            drained.fulfill()
        }
        queue.resume()
        self.wait(for: [drained], timeout: 2.0)
    }
}
