import XCTest
import AVFoundation
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

    /// A camera released without an invalidation (`CameraNeo.deinit`) follows the same order: connection changes stop,
    /// the session queue stops the session, the preview detaches on main, and only then does the session queue change
    /// the graph. The detach and the graph change never overlap, and the caller never waits for either queue.
    func testReleasingACameraStopsThenDetachesOnMainThenTearsDown() {
        var events: [String] = []
        let lock = NSLock()
        let record: (String) -> Void = { event in
            lock.lock()
            events.append(event)
            lock.unlock()
        }
        var graphChangeRunning = false
        var detachOverlappedGraphChange = false

        // The session queue is busy (a long startRunning()) and main is busy when the camera is released.
        self.sessionQueue.suspend()
        self.mainQueue.suspend()
        CameraSessionInvalidation.tearDownWithoutOwner(
            sessionQueue: self.sessionQueue,
            mainQueue: self.mainQueue,
            stopConnectionChanges: {
                record("stopConnectionChanges")
            },
            stopSession: { [sessionQueue = self.sessionQueue] in
                dispatchPrecondition(condition: .onQueue(sessionQueue))
                record("stopSession")
            },
            detachPreview: { [mainQueue = self.mainQueue] in
                dispatchPrecondition(condition: .onQueue(mainQueue))
                if graphChangeRunning {
                    detachOverlappedGraphChange = true
                }
                record("detach")
            },
            tearDown: { [sessionQueue = self.sessionQueue] in
                dispatchPrecondition(condition: .onQueue(sessionQueue))
                graphChangeRunning = true
                record("tearDown")
                graphChangeRunning = false
            }
        )
        // Returned at once: only the flag was set, nothing else ran.
        lock.lock()
        XCTAssertEqual(events, ["stopConnectionChanges"])
        lock.unlock()

        self.mainQueue.resume()
        self.sessionQueue.resume()
        self.drain([self.sessionQueue, self.mainQueue])
        lock.lock()
        XCTAssertEqual(events, ["stopConnectionChanges", "stopSession", "detach", "tearDown"])
        lock.unlock()
        XCTAssertFalse(detachOverlappedGraphChange)
    }

    func testTheDetachWaitsForTheSessionQueueToFinishStoppingEvenWhenMainIsFree() {
        var events: [String] = []
        let lock = NSLock()
        let stopFinished = DispatchSemaphore(value: 0)
        let stopMayFinish = DispatchSemaphore(value: 0)
        CameraSessionInvalidation.tearDownWithoutOwner(
            sessionQueue: self.sessionQueue,
            mainQueue: self.mainQueue,
            stopConnectionChanges: {},
            stopSession: {
                stopMayFinish.wait()
                lock.lock()
                events.append("stopSession")
                lock.unlock()
                stopFinished.signal()
            },
            detachPreview: {
                lock.lock()
                events.append("detach")
                lock.unlock()
            },
            tearDown: {}
        )
        // Main is free, but the session is still stopping: the preview stays attached.
        self.mainQueue.sync {}
        lock.lock()
        XCTAssertEqual(events, [])
        lock.unlock()
        stopMayFinish.signal()
        stopFinished.wait()
        self.drain([self.sessionQueue, self.mainQueue])
        lock.lock()
        XCTAssertEqual(events, ["stopSession", "detach"])
        lock.unlock()
    }

    func testTheOrientationTrackerSkipsAnAppliedValueAndKeepsTheLatestRequest() {
        let tracker = PreviewOrientationTracker()
        XCTAssertNil(tracker.latest)
        XCTAssertTrue(tracker.request(.portrait))
        // No connection yet, so nothing was applied: the same request must be scheduled again.
        XCTAssertTrue(tracker.request(.portrait))
        tracker.markApplied(.portrait)
        XCTAssertFalse(tracker.request(.portrait))
        XCTAssertTrue(tracker.request(.landscapeLeft))
        // Rotated back before the queue got to it: the latest request wins, and it is already applied.
        XCTAssertFalse(tracker.request(.portrait))
        XCTAssertEqual(tracker.latest, .portrait)
    }

    func testTheDetachIsLoggedBeforeAndAfter() {
        var lines: [String] = []
        CameraSessionInvalidation.logged({ lines.append($0) }) {
            lines.append("detach")
        }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first, "Camera preview detach: start")
        XCTAssertEqual(lines[1], "detach")
        XCTAssertTrue(lines[2].hasPrefix("Camera preview detach: done in "))
    }
}
