import Foundation
import SwiftSignalKit
import AnimationCompression

/// Sets up Metal for the sticker renderer (`CompressedAnimationRenderer`) before its first use.
///
/// The first Metal sticker of a process created the Metal device, loaded the shader library and
/// compiled the render pipelines on the main thread, inside the frame that showed it. `start` does
/// that once per process on a background queue; the renderers then find it done. A renderer created
/// while the setup is still running waits for it (Swift's lazy statics are initialized once,
/// thread-safely), which costs no more than doing it itself.
///
/// It runs whatever the renderer mode: "GPU for large" is the default, and the mode is only known
/// once an account context exists.
public enum AnimatedStickerMetalPrewarm {
    public enum Outcome: Equatable {
        case ready
        /// No Metal device (or no shader bundle): stickers render on the CPU anyway.
        case unavailable
    }

    private static let setupCounter = Atomic<Int>(value: 0)

    /// How many times the setup ran in this process (at most once).
    static var setupCount: Int {
        return self.setupCounter.with { $0 }
    }

    private static let outcome: Outcome = {
        let _ = AnimatedStickerMetalPrewarm.setupCounter.modify { $0 + 1 }
        return CompressedImageRenderer.prewarmSharedPipelines() ? .ready : .unavailable
    }()

    /// Starts the setup on `queue` (never call it with the main queue). Later calls only report the
    /// outcome; `completion` runs on `queue`.
    public static func start(queue: DispatchQueue = DispatchQueue.global(qos: .utility), completion: ((Outcome) -> Void)? = nil) {
        queue.async {
            let outcome = AnimatedStickerMetalPrewarm.outcome
            completion?(outcome)
        }
    }
}
