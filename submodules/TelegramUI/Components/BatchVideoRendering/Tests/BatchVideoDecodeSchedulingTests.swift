import XCTest
@testable import BatchVideoRendering

final class BatchVideoDecodeSchedulingTests: XCTestCase {
    func testPoolSizeStaysBetweenTwoAndFour() {
        XCTAssertEqual(BatchVideoDecodePlan.poolSize(activeProcessors: 1), 2)
        XCTAssertEqual(BatchVideoDecodePlan.poolSize(activeProcessors: 2), 2)
        XCTAssertEqual(BatchVideoDecodePlan.poolSize(activeProcessors: 4), 3)
        XCTAssertEqual(BatchVideoDecodePlan.poolSize(activeProcessors: 6), 4)
        XCTAssertEqual(BatchVideoDecodePlan.poolSize(activeProcessors: 16), 4)
    }

    func testQueueIndexIsRoundRobin() {
        XCTAssertEqual((0 ..< 6).map { BatchVideoDecodePlan.queueIndex(contextNumber: $0, poolSize: 3) }, [0, 1, 2, 0, 1, 2])
        XCTAssertEqual(BatchVideoDecodePlan.queueIndex(contextNumber: -1, poolSize: 3), 2)
        XCTAssertEqual(BatchVideoDecodePlan.queueIndex(contextNumber: 4, poolSize: 0), 0)
    }

    func testInFlightClaimSkipsTilesThatAreStillDecoding() {
        var inFlight = BatchVideoDecodeInFlight()
        XCTAssertEqual(inFlight.claim([1: 2, 2: 1]), [1: 2, 2: 1])
        XCTAssertEqual(inFlight.claim([1: 2, 3: 2]), [3: 2], "tile 1 still has a pass running")
        inFlight.finish(1)
        XCTAssertEqual(inFlight.claim([1: 1]), [1: 1])
        XCTAssertTrue(inFlight.contains(1))
    }

    func testFinishingEveryTileEmptiesTheTracker() {
        var inFlight = BatchVideoDecodeInFlight()
        let _ = inFlight.claim([1: 1, 2: 1])
        inFlight.finish(1)
        XCTAssertFalse(inFlight.isEmpty)
        inFlight.finish(2)
        inFlight.finish(2)
        XCTAssertTrue(inFlight.isEmpty)
    }

    func testDecodeQueuesRunWorkConcurrently() {
        let queues = (0 ..< BatchVideoDecodeQueues.count).map { _ in BatchVideoDecodeQueues.nextQueue() }
        XCTAssertEqual(Set(queues.map { ObjectIdentifier($0) }).count, BatchVideoDecodeQueues.count)
        let started = DispatchGroup()
        let release = DispatchSemaphore(value: 0)
        for queue in queues {
            started.enter()
            queue.async {
                started.leave()
                _ = release.wait(timeout: .now() + 5.0)
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5.0), .success, "a blocked queue does not hold back the others")
        for _ in queues {
            release.signal()
        }
    }

    func testParallelDecodeIsOffByDefault() {
        XCTAssertFalse(BatchVideoRenderingContext.isParallelDecodeEnabled)
    }
}
