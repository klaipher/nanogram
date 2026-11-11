import XCTest
@testable import ChatRowPrep

final class ChatViewportLoadBudgetTests: XCTestCase {
    func testTheFirstRowIsAlwaysInsideTheViewport() {
        XCTAssertTrue(ChatViewportLoadBudget.allowsSynchronousLoad(builtHeight: 0.0, viewportHeight: 600.0))
    }

    func testRowsStartingInsideTheViewportHeightLoadSynchronously() {
        XCTAssertTrue(ChatViewportLoadBudget.allowsSynchronousLoad(builtHeight: 599.0, viewportHeight: 600.0))
    }

    func testRowsPastTheViewportHeightAreInThePreloadBandAndLoadAsynchronously() {
        XCTAssertFalse(ChatViewportLoadBudget.allowsSynchronousLoad(builtHeight: 600.0, viewportHeight: 600.0))
        XCTAssertFalse(ChatViewportLoadBudget.allowsSynchronousLoad(builtHeight: 760.0, viewportHeight: 600.0))
    }

    func testAnEmptyViewportAllowsNothing() {
        XCTAssertFalse(ChatViewportLoadBudget.allowsSynchronousLoad(builtHeight: 0.0, viewportHeight: 0.0))
    }
}
