import XCTest
@testable import CameraNeo

/// Pins how CameraNeo invalidates its capture session (closing a round video).
///
/// Detaching an `AVCaptureVideoPreviewLayer` from the session (main thread) and changing the session's graph
/// (session queue) take the same AVFoundation locks in opposite orders. The round-video screen invalidated the
/// camera twice, so the first invalidation's detach ran on main while the second one tore the graph down on the
/// session queue: a deadlock, and the watchdog killed the app (0x8BADF00D). An invalidation now happens once, and
/// its teardown runs only after the detach has finished, without either queue waiting for the other.
final class CameraSessionInvalidationTests: XCTestCase {
    private let sessionQueue = DispatchQueue(label: "CameraSessionInvalidationTests.session")
    private let mainQueue = DispatchQueue(label: "CameraSessionInvalidationTests.main")

    private func drain(_ queues: [DispatchQueue]) {
        // Two passes: each queue hands work to the other once (session -> main -> session).
        for _ in 0 ..< 3 {
            for queue in queues {
                queue.sync {}
            }
        }
    }

    func testTheTeardownRunsOnlyAfterThePreviewIsDetached() {
        let invalidation = CameraSessionInvalidation()
        var events: [String] = []
        let lock = NSLock()
        let record: (String) -> Void = { event in
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        // The main thread is busy (e.g. with an animation frame) when the session queue invalidates.
        self.mainQueue.suspend()
        self.sessionQueue.sync {
            invalidation.invalidate(
                sessionQueue: self.sessionQueue,
                mainQueue: self.mainQueue,
                detachPreview: { [mainQueue = self.mainQueue] in
                    dispatchPrecondition(condition: .onQueue(mainQueue))
                    record("detach")
                },
                tearDown: { [sessionQueue = self.sessionQueue] in
                    dispatchPrecondition(condition: .onQueue(sessionQueue))
                    record("tearDown")
                }
            )
            XCTAssertTrue(invalidation.isInvalidated)
        }
        // The session queue is free again, and it has not touched the graph: the detach has not happened yet.
        self.sessionQueue.sync {}
        lock.lock()
        XCTAssertEqual(events, [])
        lock.unlock()

        self.mainQueue.resume()
        self.drain([self.mainQueue, self.sessionQueue])
        lock.lock()
        XCTAssertEqual(events, ["detach", "tearDown"])
        lock.unlock()
    }

    func testASecondInvalidationDoesNothing() {
        let invalidation = CameraSessionInvalidation()
        var detachCount = 0
        var tearDownCount = 0

        for _ in 0 ..< 2 {
            self.sessionQueue.async {
                invalidation.invalidate(
                    sessionQueue: self.sessionQueue,
                    mainQueue: self.mainQueue,
                    detachPreview: { detachCount += 1 },
                    tearDown: { tearDownCount += 1 }
                )
            }
        }
        self.drain([self.sessionQueue, self.mainQueue])
        // And once more after the first one has completed.
        self.sessionQueue.sync {
            invalidation.invalidate(
                sessionQueue: self.sessionQueue,
                mainQueue: self.mainQueue,
                detachPreview: { detachCount += 1 },
                tearDown: { tearDownCount += 1 }
            )
        }
        self.drain([self.sessionQueue, self.mainQueue])

        self.sessionQueue.sync {
            XCTAssertEqual(detachCount, 1)
            XCTAssertEqual(tearDownCount, 1)
        }
    }

    func testDeinitTearsDownOnlyACameraThatWasNeverInvalidated() {
        let invalidation = CameraSessionInvalidation()
        self.sessionQueue.sync {
            XCTAssertFalse(invalidation.isInvalidated)
            XCTAssertTrue(invalidation.needsTearDownOnDeinit)
            invalidation.invalidate(
                sessionQueue: self.sessionQueue,
                mainQueue: self.mainQueue,
                detachPreview: {},
                tearDown: {}
            )
            // The invalidation owns the teardown from here on, even before it has run.
            XCTAssertFalse(invalidation.needsTearDownOnDeinit)
        }
        self.drain([self.sessionQueue, self.mainQueue])
        self.sessionQueue.sync {
            XCTAssertFalse(invalidation.needsTearDownOnDeinit)
        }
    }

    /// The preview connection is switched on the session queue (`CameraPreviewView.connectionQueue`). Once the
    /// camera is invalidated the layer is about to be detached on main, so a switch still queued then must not run.
    func testConnectionChangesQueuedAfterInvalidationAreDropped() {
        let queue = DispatchQueue(label: "CameraSessionInvalidationTests.connection")
        var isStopped = false
        var applied: [String] = []

        queue.suspend()
        CameraPreviewView.performConnectionChange(on: queue, isStopped: { isStopped }) {
            applied.append("before")
        }
        queue.async {
            isStopped = true
        }
        CameraPreviewView.performConnectionChange(on: queue, isStopped: { isStopped }) {
            applied.append("after")
        }
        queue.resume()
        queue.sync {
            XCTAssertEqual(applied, ["before"])
        }
    }
}
