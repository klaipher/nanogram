import Foundation
import XCTest
import Metal
@testable import AnimatedStickerNode

// The first Metal sticker of a process set up the Metal device, the shader library and the render
// pipelines on the main thread, inside the frame that showed it. The app now does that once, on a
// utility queue, shortly after launch. These tests pin that the prewarm runs its setup once however
// often and from wherever it is started, never on the main thread, and never traps where the process
// has no Metal device (this test process has none; the setup then reports unavailable).
final class MetalPrewarmTests: XCTestCase {
    func testPrewarmSetsUpOnceOffTheMainThread() {
        let callCount = 8
        let lock = NSLock()
        var outcomes: [AnimatedStickerMetalPrewarm.Outcome] = []
        var ranOnMain = false
        let done = self.expectation(description: "prewarm completions")
        done.expectedFulfillmentCount = callCount

        let completion: (AnimatedStickerMetalPrewarm.Outcome) -> Void = { outcome in
            lock.lock()
            outcomes.append(outcome)
            if Thread.isMainThread {
                ranOnMain = true
            }
            lock.unlock()
            done.fulfill()
        }
        // From the main thread, as the app delegate does, and concurrently from other threads.
        AnimatedStickerMetalPrewarm.start(completion: completion)
        DispatchQueue.concurrentPerform(iterations: callCount - 1) { _ in
            AnimatedStickerMetalPrewarm.start(completion: completion)
        }
        self.wait(for: [done], timeout: 30.0)

        XCTAssertEqual(AnimatedStickerMetalPrewarm.setupCount, 1, "the setup runs once per process")
        XCTAssertFalse(ranOnMain, "the setup and its completion stay off the main thread")
        let expected: AnimatedStickerMetalPrewarm.Outcome = MTLCreateSystemDefaultDevice() == nil ? .unavailable : .ready
        XCTAssertEqual(outcomes, Array(repeating: expected, count: callCount))
    }
}
