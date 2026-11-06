import Foundation
import AVFoundation

/// Invalidates a camera's capture session once: detaches the preview layers from it on the main thread, then tears
/// its graph down on the session queue.
///
/// Lock ordering: setting `AVCaptureVideoPreviewLayer.session` (main thread) and changing the session's graph
/// (`beginConfiguration`/`removeInput`/`removeOutput`, session queue) take the same AVFoundation locks in opposite
/// orders, so the two must never overlap. Run together they deadlocked closing a round video, the main thread stuck
/// until the watchdog killed the app (0x8BADF00D). So: the session queue marks the camera invalidated (from then on
/// no session-queue work changes the graph or the preview connections), hands the detach to the main thread, and
/// the main thread hands the teardown back to the session queue once the detach is done. Neither queue ever waits
/// for the other, and the main thread never waits for the session queue (`CameraNeo.deinit` hands its clean-up to
/// the session queue with `async`; a `sync` there held the main thread for as long as `stopRunning()` took).
///
/// Confined to the session queue.
final class CameraSessionInvalidation {
    private enum State {
        case active
        case invalidated
        case tornDown
    }

    private var state: State = .active

    var isInvalidated: Bool {
        return self.state != .active
    }

    /// Whether `CameraNeo.deinit` still has to tear the session down: not once an invalidation owns the teardown.
    var needsTearDownOnDeinit: Bool {
        return self.state == .active
    }

    /// Call on `sessionQueue`. Only the first call does anything: `detachPreview` runs on `mainQueue`, then
    /// `tearDown` on `sessionQueue`. Both closures are retained until they have run.
    func invalidate(sessionQueue: DispatchQueue, mainQueue: DispatchQueue, detachPreview: @escaping () -> Void, tearDown: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard self.state == .active else {
            return
        }
        self.state = .invalidated
        mainQueue.async {
            detachPreview()
            sessionQueue.async {
                self.state = .tornDown
                tearDown()
            }
        }
    }

    /// Runs the main-thread detach with a log line before and after it, so a hang inside AVFoundation's lock
    /// (`AVCaptureVideoPreviewLayer.session = nil`) can be attributed to it in the next report.
    static func logged(_ log: ((String) -> Void)?, _ detach: () -> Void) {
        log?("Camera preview detach: start")
        let start = CFAbsoluteTimeGetCurrent()
        detach()
        log?("Camera preview detach: done in \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000.0)) ms")
    }

    /// The same hand-off for a camera that is released without having been invalidated (`CameraNeo.deinit`, which owns
    /// nothing but what the closures capture). Order: `stopConnectionChanges` (any thread, a flag), then on
    /// `sessionQueue` `stopSession`, then on `mainQueue` `detachPreview`, then back on `sessionQueue` `tearDown`.
    /// `detachPreview` captures the preview views strongly, so their layers cannot detach on their own (on main, while
    /// the graph is changing on the session queue) before then. Nothing here waits for another queue.
    static func tearDownWithoutOwner(sessionQueue: DispatchQueue, mainQueue: DispatchQueue, stopConnectionChanges: () -> Void, stopSession: @escaping () -> Void, detachPreview: @escaping () -> Void, tearDown: @escaping () -> Void) {
        stopConnectionChanges()
        sessionQueue.async {
            stopSession()
            mainQueue.async {
                detachPreview()
                sessionQueue.async {
                    tearDown()
                }
            }
        }
    }
}

/// The orientation a preview layer should have, shared by main (which requests it) and the session queue (which applies
/// it to the connection). The latest request wins: a queued change applies the value requested last, not the one it was
/// queued with, so a busy queue never ends with a stale orientation. A request equal to the one already applied to a
/// connection is skipped; one made while there is no connection yet (before the session is configured) is not "applied".
final class PreviewOrientationTracker {
    private let lock = NSLock()
    private var requested: AVCaptureVideoOrientation?
    private var applied: AVCaptureVideoOrientation?

    /// The orientation requested last, if any.
    var latest: AVCaptureVideoOrientation? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.requested
    }

    /// Records the request; returns whether a change has to be scheduled (not if it is already applied).
    func request(_ orientation: AVCaptureVideoOrientation) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.requested = orientation
        return self.applied != orientation
    }

    /// Records that `orientation` was set on a connection.
    func markApplied(_ orientation: AVCaptureVideoOrientation) {
        self.lock.lock()
        self.applied = orientation
        self.lock.unlock()
    }
}
