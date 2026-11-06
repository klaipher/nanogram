import Foundation

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
}
