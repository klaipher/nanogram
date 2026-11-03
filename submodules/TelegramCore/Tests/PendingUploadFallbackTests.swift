import XCTest
import SwiftSignalKit
@testable import TelegramCore

final class PendingUploadFallbackTests: XCTestCase {
    private func collect<T, E>(_ signal: Signal<T, E>) -> (values: [T], completed: Bool, failed: Bool) {
        var values: [T] = []
        var completed = false
        var failed = false
        let _ = signal.start(next: { values.append($0) }, error: { _ in failed = true }, completed: { completed = true })
        return (values, completed, failed)
    }

    func testASignalThatCompletesWithoutAValueYieldsTheFallback() {
        let result = collect((Signal<Int, NoError>.complete() |> pendingUploadFallback(7)))
        XCTAssertEqual(result.values, [7])
        XCTAssertTrue(result.completed)
    }

    func testASignalThatYieldsAValueIsLeftAlone() {
        let result = collect((Signal<Int, NoError>.single(3) |> pendingUploadFallback(7)))
        XCTAssertEqual(result.values, [3])
        XCTAssertTrue(result.completed)
    }

    func testASignalThatNeverCompletesYieldsNothingYet() {
        let result = collect((Signal<Int, NoError>.never() |> pendingUploadFallback(7)))
        XCTAssertEqual(result.values, [])
        XCTAssertFalse(result.completed)
    }

    func testAnErrorIsNotReplacedByTheFallback() {
        let result = collect((Signal<Int, String>.fail("x") |> pendingUploadFallback(7)))
        XCTAssertEqual(result.values, [])
        XCTAssertTrue(result.failed)
    }

    func testProgressMilestonesReportEachQuarterOnce() {
        var milestones = PendingUploadProgressMilestones()
        XCTAssertEqual(milestones.reached(0.1), [])
        XCTAssertEqual(milestones.reached(0.26), [25])
        XCTAssertEqual(milestones.reached(0.3), [])
        XCTAssertEqual(milestones.reached(0.8), [50, 75])
        XCTAssertEqual(milestones.reached(1.0), [100])
        XCTAssertEqual(milestones.reached(1.0), [])
    }
}
