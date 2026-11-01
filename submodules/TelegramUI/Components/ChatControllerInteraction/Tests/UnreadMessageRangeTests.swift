import Foundation
import XCTest

final class UnreadMessageRangeTests: XCTestCase {
    func testOrdinaryValuesMatchThePreviousArithmetic() {
        // No range yet, no earlier read state: everything after the read mark.
        XCTAssertEqual(updatedUnreadMessageRange(current: nil, previousMaxIncomingReadId: nil, maxIncomingReadId: 100), 101 ..< (Int32.max - 1))
        // No range yet, the read mark moved: what was read just now.
        XCTAssertEqual(updatedUnreadMessageRange(current: nil, previousMaxIncomingReadId: 90, maxIncomingReadId: 100), 91 ..< 101)
        // A range grows up to the new read mark.
        XCTAssertEqual(updatedUnreadMessageRange(current: 91 ..< 101, previousMaxIncomingReadId: 100, maxIncomingReadId: 120), 91 ..< 121)
        XCTAssertEqual(updatedUnreadMessageRange(current: 91 ..< 101, previousMaxIncomingReadId: nil, maxIncomingReadId: 120), 91 ..< 121)
        // And never shrinks.
        XCTAssertEqual(updatedUnreadMessageRange(current: 91 ..< 201, previousMaxIncomingReadId: 100, maxIncomingReadId: 120), 91 ..< 201)
    }

    func testServerExtremesDoNotTrap() {
        for maxId in [Int32.max, Int32.max - 1, Int32.max - 2, 0, Int32.min] {
            let fresh = updatedUnreadMessageRange(current: nil, previousMaxIncomingReadId: nil, maxIncomingReadId: maxId)
            XCTAssertNotNil(fresh)
            if maxId >= Int32.max - 2 {
                XCTAssertEqual(fresh?.isEmpty, true)
            }
            let moved = updatedUnreadMessageRange(current: nil, previousMaxIncomingReadId: Int32.min, maxIncomingReadId: maxId)
            XCTAssertNotNil(moved)
            let grown = updatedUnreadMessageRange(current: 0 ..< 1, previousMaxIncomingReadId: 0, maxIncomingReadId: maxId)
            XCTAssertNotNil(grown)
        }
        XCTAssertEqual(updatedUnreadMessageRange(current: nil, previousMaxIncomingReadId: Int32.max - 1, maxIncomingReadId: Int32.max), Int32.max ..< Int32.max)
        XCTAssertEqual(updatedUnreadMessageRange(current: 5 ..< 10, previousMaxIncomingReadId: 9, maxIncomingReadId: Int32.max), 5 ..< Int32.max)
    }

    func testInvertedReadMarksDoNotTrap() {
        // The caller only asks when the mark did not move back; an inverted pair must still not trap.
        XCTAssertEqual(updatedUnreadMessageRange(current: nil, previousMaxIncomingReadId: 100, maxIncomingReadId: 50), nil)
        // With a range, only the new mark matters, as before.
        XCTAssertEqual(updatedUnreadMessageRange(current: 1 ..< 10, previousMaxIncomingReadId: 100, maxIncomingReadId: 50), 1 ..< 51)
    }
}
