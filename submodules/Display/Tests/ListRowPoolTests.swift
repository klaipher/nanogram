import XCTest
@testable import Display

final class ListRowPoolTests: XCTestCase {
    private final class N {}
    
    private var scheduled: [() -> Void] = []
    private var prepared: [N] = []
    private var accept: (N) -> Bool = { _ in true }
    
    override func setUp() {
        super.setUp()
        self.scheduled = []
        self.prepared = []
        self.accept = { _ in true }
    }
    
    private func makePool(capacity: Int) -> ListRowPool<N> {
        return ListRowPool<N>(capacity: capacity, schedule: { [unowned self] block in
            self.scheduled.append(block)
        }, prepare: { [unowned self] node in
            self.prepared.append(node)
            return self.accept(node)
        })
    }
    
    private func runScheduled() {
        let blocks = self.scheduled
        self.scheduled = []
        for block in blocks {
            block()
        }
    }
    
    func testNeverExceedsCapacityCountingPending() {
        let pool = self.makePool(capacity: 2)
        let a = N(), b = N(), c = N()
        pool.offer(a)
        pool.offer(b)
        pool.offer(c)
        XCTAssertEqual(pool.pendingCount, 2)
        XCTAssertEqual(pool.readyCount, 0)
        self.runScheduled()
        XCTAssertEqual(pool.pendingCount + pool.readyCount, 2)
        XCTAssertTrue(self.prepared.contains(where: { $0 === a }))
        XCTAssertTrue(self.prepared.contains(where: { $0 === b }))
        XCTAssertFalse(self.prepared.contains(where: { $0 === c }))
    }
    
    func testOldestReadyIsEvictedFirst() {
        let pool = self.makePool(capacity: 2)
        let a = N(), b = N(), c = N()
        pool.offer(a)
        pool.offer(b)
        self.runScheduled()
        XCTAssertEqual(pool.readyCount, 2)
        pool.offer(c)
        self.runScheduled()
        XCTAssertEqual(pool.readyCount, 2)
        let first = pool.take(where: { _ in true })
        let second = pool.take(where: { _ in true })
        XCTAssertTrue(first === c)
        XCTAssertTrue(second === b)
        XCTAssertNil(pool.take(where: { _ in true }))
    }
    
    func testTakeReturnsMostRecentlyPrepared() {
        let pool = self.makePool(capacity: 4)
        let a = N(), b = N()
        pool.offer(a)
        pool.offer(b)
        self.runScheduled()
        XCTAssertTrue(pool.take(where: { _ in true }) === b)
        XCTAssertTrue(pool.take(where: { _ in true }) === a)
    }
    
    func testNotAvailableUntilPrepareRan() {
        let pool = self.makePool(capacity: 4)
        pool.offer(N())
        XCTAssertNil(pool.take(where: { _ in true }))
        XCTAssertTrue(self.prepared.isEmpty)
        self.runScheduled()
        XCTAssertEqual(self.prepared.count, 1)
        XCTAssertNotNil(pool.take(where: { _ in true }))
    }
    
    func testDrainCancelsQueuedPrepares() {
        let pool = self.makePool(capacity: 4)
        pool.offer(N())
        pool.drain()
        XCTAssertEqual(pool.pendingCount, 0)
        self.runScheduled()
        XCTAssertTrue(self.prepared.isEmpty)
        XCTAssertEqual(pool.readyCount, 0)
        
        // The pool works again after a drain.
        pool.offer(N())
        self.runScheduled()
        XCTAssertEqual(pool.readyCount, 1)
    }
    
    func testDrainRemovesReadyNodes() {
        let pool = self.makePool(capacity: 4)
        pool.offer(N())
        self.runScheduled()
        XCTAssertEqual(pool.readyCount, 1)
        pool.drain()
        XCTAssertEqual(pool.readyCount, 0)
    }
    
    func testRefusedPrepareDropsTheNode() {
        let pool = self.makePool(capacity: 4)
        self.accept = { _ in false }
        pool.offer(N())
        self.runScheduled()
        XCTAssertEqual(self.prepared.count, 1)
        XCTAssertEqual(pool.readyCount, 0)
        XCTAssertEqual(pool.pendingCount, 0)
    }
    
    func testDuplicateOfferIgnored() {
        let pool = self.makePool(capacity: 4)
        let a = N()
        pool.offer(a)
        pool.offer(a)
        XCTAssertEqual(pool.pendingCount, 1)
        self.runScheduled()
        pool.offer(a)
        XCTAssertEqual(pool.pendingCount, 0)
        XCTAssertEqual(pool.readyCount, 1)
    }
    
    func testCapacityZeroStoresNothing() {
        let pool = self.makePool(capacity: 0)
        pool.offer(N())
        XCTAssertEqual(pool.pendingCount, 0)
        XCTAssertTrue(self.scheduled.isEmpty)
        XCTAssertNil(pool.take(where: { _ in true }))
    }
    
    func testUnusableNodesAreDroppedByTake() {
        let pool = self.makePool(capacity: 4)
        let a = N(), b = N()
        pool.offer(a)
        pool.offer(b)
        self.runScheduled()
        let taken = pool.take(where: { $0 === a })
        XCTAssertTrue(taken === a)
        // b was met first and was dropped.
        XCTAssertEqual(pool.readyCount, 0)
    }
    
    func testOneScheduleForABatch() {
        let pool = self.makePool(capacity: 8)
        pool.offer(N())
        pool.offer(N())
        pool.offer(N())
        XCTAssertEqual(self.scheduled.count, 1)
        self.runScheduled()
        pool.offer(N())
        XCTAssertEqual(self.scheduled.count, 1)
    }
}
