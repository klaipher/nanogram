import XCTest
@testable import TelegramCore

final class ChatThemesRequestGateTests: XCTestCase {
    func testTheFirstRequestForAHashGoesOut() {
        let gate = ChatThemesRequestGate()
        XCTAssertTrue(gate.shouldRequest(hash: 42, now: 100.0))
    }

    func testTheSameHashIsNotRequestedAgainWithinTenMinutes() {
        let gate = ChatThemesRequestGate()
        XCTAssertTrue(gate.shouldRequest(hash: 42, now: 100.0))
        XCTAssertFalse(gate.shouldRequest(hash: 42, now: 101.0), "still in flight or just answered")
        XCTAssertFalse(gate.shouldRequest(hash: 42, now: 100.0 + ChatThemesRequestGate.timeToLive - 1.0))
        XCTAssertTrue(gate.shouldRequest(hash: 42, now: 100.0 + ChatThemesRequestGate.timeToLive))
    }

    func testAnotherHashGoesOut() {
        let gate = ChatThemesRequestGate()
        XCTAssertTrue(gate.shouldRequest(hash: 1, now: 100.0))
        XCTAssertTrue(gate.shouldRequest(hash: 2, now: 101.0))
    }

    func testAnUnansweredRequestCanBeTriedAgain() {
        let gate = ChatThemesRequestGate()
        XCTAssertTrue(gate.shouldRequest(hash: 42, now: 100.0))
        gate.forget(hash: 42)
        XCTAssertTrue(gate.shouldRequest(hash: 42, now: 101.0))
    }

    func testAFreshListCountsTheNewHashAsChecked() {
        let gate = ChatThemesRequestGate()
        gate.noteFresh(hash: 7, now: 100.0)
        XCTAssertFalse(gate.shouldRequest(hash: 7, now: 150.0))
    }
}
