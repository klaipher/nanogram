import XCTest
@testable import tgwatch_Watch_App

/// Each row used to get its index and the row count, so a new message (count) or an older page
/// (every index) changed every row's inputs and SwiftUI re-ran every row's body. Rows now get
/// two edge flags and compare equal on their data, so only the rows that changed re-render.
@MainActor
final class CoreMessageRowViewTests: XCTestCase {
    func testEdgeFlagsMatchTheOldIndexChecks() {
        for count in 0...8 {
            for index in 0..<max(count, 1) {
                let flags = MessageRowView.edges(index: index, count: count)
                XCTAssertEqual(flags.nearTop, index <= 2, "index \(index) count \(count)")
                XCTAssertEqual(flags.nearBottom, index >= count - 3, "index \(index) count \(count)")
            }
        }
    }

    /// A message appended at the bottom leaves the flags of every row but the last three alone.
    func testAppendingAMessageChangesOnlyTheBottomRowsFlags() {
        let before = (0..<40).map { MessageRowView.edges(index: $0, count: 40) }
        let after = (0..<40).map { MessageRowView.edges(index: $0, count: 41) }
        let changed = (0..<40).filter { before[$0] != after[$0] }
        XCTAssertEqual(changed, [37])
    }

    func testRowsCompareOnDataNotClosures() {
        let row = MessageRow.daySeparator(DayLabel(key: "2026-11-02", label: "Today"))
        let a = MessageRowView(row: row, onPhotoTap: { _ in }, onVideoTap: { _ in }, onVideoNoteTap: { _ in },
                               onPollTap: { _, _ in }, isNearTop: false, isNearBottom: true)
        let b = MessageRowView(row: row, onPhotoTap: { _ in }, onVideoTap: { _ in }, onVideoNoteTap: { _ in },
                               onPollTap: { _, _ in }, isNearTop: false, isNearBottom: true)
        let c = MessageRowView(row: row, onPhotoTap: { _ in }, onVideoTap: { _ in }, onVideoNoteTap: { _ in },
                               onPollTap: { _, _ in }, isNearTop: true, isNearBottom: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
