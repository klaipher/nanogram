import Foundation
import XCTest
import SwiftSignalKit
@testable import AnimatedStickerNode

final class AnimatedStickerQueuePoolTests: XCTestCase {
    private var savedEnabled = false

    override func setUp() {
        super.setUp()
        self.savedEnabled = AnimatedStickerQueuePool.isEnabled
    }

    override func tearDown() {
        AnimatedStickerQueuePool.isEnabled = self.savedEnabled
        super.tearDown()
    }

    func testQueueIndexWrapsAroundThePool() {
        XCTAssertEqual((0 ..< 7).map { animatedStickerQueueIndex(nodeNumber: $0, poolSize: 3) }, [0, 1, 2, 0, 1, 2, 0])
        XCTAssertEqual(animatedStickerQueueIndex(nodeNumber: -1, poolSize: 3), 2)
        XCTAssertEqual(animatedStickerQueueIndex(nodeNumber: 5, poolSize: 0), 0)
    }

    func testDisabledPoolHandsEveryNodeTheLegacySharedQueue() {
        AnimatedStickerQueuePool.isEnabled = false
        for _ in 0 ..< 5 {
            XCTAssertTrue(AnimatedStickerQueuePool.queueForNewNode() === animatedStickerLegacySharedQueue)
        }
    }

    func testEnabledPoolSpreadsNodesOverEveryPooledQueue() {
        AnimatedStickerQueuePool.isEnabled = true
        let handedOut = (0 ..< AnimatedStickerQueuePool.poolSize * 4).map { _ in AnimatedStickerQueuePool.queueForNewNode() }
        let pooled = AnimatedStickerQueuePool.pooledQueues
        XCTAssertEqual(pooled.count, AnimatedStickerQueuePool.poolSize)
        for queue in pooled {
            XCTAssertEqual(handedOut.filter { $0 === queue }.count, 4)
        }
        XCTAssertFalse(handedOut.contains(where: { $0 === animatedStickerLegacySharedQueue }))
    }

    func testPooledQueuesRunWorkConcurrently() {
        let pooled = AnimatedStickerQueuePool.pooledQueues
        let started = DispatchGroup()
        let release = DispatchSemaphore(value: 0)
        for queue in pooled {
            started.enter()
            queue.async {
                started.leave()
                _ = release.wait(timeout: .now() + 5.0)
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5.0), .success, "each pooled queue runs its own work while the others are busy")
        for _ in pooled {
            release.signal()
        }
    }
}
