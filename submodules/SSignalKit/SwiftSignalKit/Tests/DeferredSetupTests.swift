import XCTest
import SwiftSignalKit

final class DeferredSetupTests: XCTestCase {
    func testDisabledRunsAtOnceInOrder() {
        let setup = DeferredSetup(isEnabled: false)
        var log: [Int] = []
        setup.run { log.append(1) }
        setup.run { log.append(2) }
        XCTAssertEqual(log, [1, 2])
        XCTAssertEqual(setup.pendingCount, 0)
        setup.flush()
        XCTAssertEqual(log, [1, 2], "a flush of a disabled queue has nothing to run")
    }

    func testEnabledKeepsTheWorkUntilFlushAndRunsItInOrder() {
        let setup = DeferredSetup(isEnabled: true)
        var log: [Int] = []
        setup.run { log.append(1) }
        setup.run { log.append(2) }
        setup.run { log.append(3) }
        XCTAssertEqual(log, [])
        XCTAssertEqual(setup.pendingCount, 3)
        setup.flush()
        XCTAssertEqual(log, [1, 2, 3])
        XCTAssertEqual(setup.pendingCount, 0)
    }

    func testFlushRunsEverythingOnlyOnce() {
        let setup = DeferredSetup(isEnabled: true)
        var count = 0
        setup.run { count += 1 }
        setup.flush()
        setup.flush()
        XCTAssertEqual(count, 1)
    }

    func testWorkSubmittedAfterTheFlushRunsAtOnce() {
        let setup = DeferredSetup(isEnabled: true)
        setup.flush()
        var ran = false
        setup.run { ran = true }
        XCTAssertTrue(ran)
        XCTAssertEqual(setup.pendingCount, 0)
    }

    func testWorkSubmittedByDeferredWorkRunsAtOnce() {
        let setup = DeferredSetup(isEnabled: true)
        var log: [String] = []
        setup.run {
            log.append("outer")
            setup.run { log.append("inner") }
            log.append("outer end")
        }
        setup.flush()
        XCTAssertEqual(log, ["outer", "inner", "outer end"])
    }

    func testDiscardDropsTheWorkAndLaterWorkRunsAtOnce() {
        let setup = DeferredSetup(isEnabled: true)
        var count = 0
        setup.run { count += 1 }
        setup.discard()
        setup.flush()
        XCTAssertEqual(count, 0)
        setup.run { count += 10 }
        XCTAssertEqual(count, 10)
    }
}
