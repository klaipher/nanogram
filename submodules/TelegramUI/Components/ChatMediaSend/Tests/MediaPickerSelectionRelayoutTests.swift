import XCTest
import ChatMediaSend

final class MediaPickerSelectionRelayoutTests: XCTestCase {
    func testVisiblePickerRelaysOutAtOnce() {
        var gate = MediaPickerSelectionRelayoutGate()
        XCTAssertTrue(gate.selectionChanged(isCovered: false))
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.coverEnded())
    }

    func testCoveredPickerHoldsBackAndRunsOnceWhenVisibleAgain() {
        var gate = MediaPickerSelectionRelayoutGate()
        XCTAssertFalse(gate.selectionChanged(isCovered: true))
        XCTAssertFalse(gate.selectionChanged(isCovered: true))
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.coverEnded())
        XCTAssertFalse(gate.coverEnded())
    }
}
