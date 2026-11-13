import XCTest
@testable import PremiumCoinComponent

final class DeferredSetupTests: XCTestCase {
    func testRequestDoesNotRunTheWorkInline() {
        var pending: [() -> Void] = []
        var runs = 0
        let setup = DeferredSetup(schedule: { pending.append($0) }, work: { runs += 1 })
        setup.request()
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(pending.count, 1)
        pending.removeFirst()()
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(setup.didRun)
    }

    func testWorkRunsOnceForRepeatedRequests() {
        var pending: [() -> Void] = []
        var runs = 0
        let setup = DeferredSetup(schedule: { pending.append($0) }, work: { runs += 1 })
        setup.request()
        setup.request()
        XCTAssertEqual(pending.count, 1)
        while !pending.isEmpty {
            pending.removeFirst()()
        }
        XCTAssertEqual(runs, 1)
    }

    func testCancelledSetupNeverRuns() {
        var pending: [() -> Void] = []
        var runs = 0
        let setup = DeferredSetup(schedule: { pending.append($0) }, work: { runs += 1 })
        setup.request()
        setup.cancel()
        pending.removeFirst()()
        XCTAssertEqual(runs, 0)
        XCTAssertFalse(setup.didRun)
    }
}
