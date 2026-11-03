import Foundation

/// The objects a video frame's GPU textures depend on (the `CVMetalTexture`s and, through them,
/// the camera or decoder `CVPixelBuffer`). A `CVMetalTexture` must outlive every command buffer
/// that samples its `MTLTexture`; releasing it right after `CVMetalTextureGetTexture` lets the
/// pixel buffer return to the decoder or camera pool while the GPU still reads it, which shows
/// as flicker or torn frames under load.
final class GPUFrameResourceLease {
    private var resources: [AnyObject]

    init(resources: [AnyObject]) {
        self.resources = resources
    }

    /// Keeps the resources alive until `registerCompletion` calls its handler, which for a Metal
    /// command buffer is `addCompletedHandler`.
    func hold(until registerCompletion: (@escaping () -> Void) -> Void) {
        let lease = self
        registerCompletion {
            lease.release()
        }
    }

    private func release() {
        self.resources.removeAll()
    }
}

/// The renderer's "current frame" resources. Replacing them never releases what a command buffer
/// already encoded: each encode takes `currentLease` and holds it until that command buffer
/// completes, so only a frame that was never drawn is released by its successor.
struct GPUFrameResourceState {
    private(set) var currentLease: GPUFrameResourceLease?

    mutating func update(resources: [AnyObject]) {
        self.currentLease = GPUFrameResourceLease(resources: resources)
    }

    mutating func clear() {
        self.currentLease = nil
    }
}
