import XCTest
import UIKit
@testable import Display

/// Row accessibility strings (chat list rows, message bubbles) were built inside each row's layout,
/// which runs on the main thread in scroll frames. They are now built once rows stop arriving.
final class ListViewDeferredAccessibilityTests: XCTestCase {
    private final class Owner {}

    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func test_runsOnlyAfterRequestsStopArriving() {
        let deferred = ListViewDeferredAccessibility(quietInterval: 0.1, batchSize: 8, isImmediate: { false })
        let owner = Owner()
        var runs = 0
        deferred.request(owner: owner) { runs += 1 }
        XCTAssertEqual(runs, 0)
        // New rows keep arriving (a scroll): nothing runs.
        for _ in 0 ..< 5 {
            spin(0.04)
            deferred.request(owner: Owner()) {}
        }
        XCTAssertEqual(runs, 0)
        spin(0.4)
        XCTAssertEqual(runs, 1)
    }

    func test_coalescesPerOwnerAndRunsTheLatestBlock() {
        let deferred = ListViewDeferredAccessibility(quietInterval: 0.05, batchSize: 8, isImmediate: { false })
        let owner = Owner()
        var values: [Int] = []
        deferred.request(owner: owner) { values.append(1) }
        deferred.request(owner: owner) { values.append(2) }
        spin(0.3)
        XCTAssertEqual(values, [2])
    }

    func test_skipsOwnersThatWentAway() {
        let deferred = ListViewDeferredAccessibility(quietInterval: 0.05, batchSize: 8, isImmediate: { false })
        var runs = 0
        do {
            let owner = Owner()
            deferred.request(owner: owner) { runs += 1 }
        }
        spin(0.3)
        XCTAssertEqual(runs, 0)
    }

    func test_runsAtOnceWhileAssistiveTechnologyIsOn() {
        let deferred = ListViewDeferredAccessibility(quietInterval: 10.0, batchSize: 8, isImmediate: { true })
        var runs = 0
        deferred.request(owner: Owner()) { runs += 1 }
        XCTAssertEqual(runs, 1)
    }

    func test_flushesInBatchesAcrossRunLoopTurns() {
        let deferred = ListViewDeferredAccessibility(quietInterval: 0.05, batchSize: 3, isImmediate: { false })
        let owners = (0 ..< 10).map { _ in Owner() }
        var order: [Int] = []
        for (index, owner) in owners.enumerated() {
            deferred.request(owner: owner) { order.append(index) }
        }
        spin(0.5)
        XCTAssertEqual(order, Array(0 ..< 10))
    }

    func test_overheadPerRequest() {
        let deferred = ListViewDeferredAccessibility(quietInterval: 10.0, batchSize: 8, isImmediate: { false })
        let owners = (0 ..< 1000).map { _ in Owner() }
        let start = CACurrentMediaTime()
        for owner in owners {
            deferred.request(owner: owner) {}
        }
        let perRequestUs = (CACurrentMediaTime() - start) * 1e6 / Double(owners.count)
        print("ListViewDeferredAccessibilityTests: \(String(format: "%.2f", perRequestUs)) us per request")
        XCTAssertLessThan(perRequestUs, 50.0)
    }
}
