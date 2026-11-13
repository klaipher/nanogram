import XCTest
@testable import TelegramCallsUI

final class CallKitPendingActionsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testAnActionIsAppliedOnceToExactlyItsCall() {
        var pending = CallKitPendingActions()
        let call = UUID()
        pending.store(.answer, uuid: call, now: self.start)
        XCTAssertNil(pending.take(uuid: UUID(), now: self.start))
        XCTAssertEqual(pending.take(uuid: call, now: self.start.addingTimeInterval(1)), .answer)
        XCTAssertNil(pending.take(uuid: call, now: self.start.addingTimeInterval(1)))
    }

    func testAnActionExpiresAfterTenSeconds() {
        var pending = CallKitPendingActions()
        let call = UUID()
        pending.store(.answer, uuid: call, now: self.start)
        XCTAssertNil(pending.take(uuid: call, now: self.start.addingTimeInterval(10.5)))
        XCTAssertTrue(pending.isEmpty)
    }

    func testAnActionAtTheTimeoutBoundaryStillApplies() {
        var pending = CallKitPendingActions()
        let call = UUID()
        pending.store(.end, uuid: call, now: self.start)
        XCTAssertEqual(pending.take(uuid: call, now: self.start.addingTimeInterval(10)), .end)
    }

    func testEndOutlivesAnswerForTheSameCall() {
        var pending = CallKitPendingActions()
        let call = UUID()
        pending.store(.answer, uuid: call, now: self.start)
        pending.store(.end, uuid: call, now: self.start.addingTimeInterval(1))
        pending.store(.answer, uuid: call, now: self.start.addingTimeInterval(2))
        XCTAssertEqual(pending.take(uuid: call, now: self.start.addingTimeInterval(3)), .end)
    }

    func testCallsAreIndependent() {
        var pending = CallKitPendingActions()
        let first = UUID()
        let second = UUID()
        pending.store(.answer, uuid: first, now: self.start)
        pending.store(.end, uuid: second, now: self.start)
        XCTAssertEqual(pending.take(uuid: second, now: self.start), .end)
        XCTAssertEqual(pending.take(uuid: first, now: self.start), .answer)
    }
}
