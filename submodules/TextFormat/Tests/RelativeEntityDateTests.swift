import XCTest
@testable import TextFormat

/// A date entity's timestamp is chosen by the sender. `now - timestamp` and `abs(...)` in Int32
/// trapped for Int32.min and for dates far in the future.
final class RelativeEntityDateTests: XCTestCase {
    private let now: Int64 = 1_800_000_000

    func testOrdinaryDatesAreUnchanged() {
        XCTAssertEqual(relativeEntityDate(timestamp: Int32(clamping: now - 30), now: now), .secondsAgo(30))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32(clamping: now - 90), now: now), .minutesAgo(2))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32(clamping: now - 3600), now: now), .minutesAgo(60))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32(clamping: now - 5400), now: now), .hoursAgo(2))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32(clamping: now - 86400 * 3), now: now), .daysAgo(3))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32(clamping: now), now: now), .inSeconds(0))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32(clamping: now + 45), now: now), .inSeconds(45))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32(clamping: now + 600), now: now), .inMinutes(10))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32(clamping: now + 7200), now: now), .inHours(2))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32(clamping: now + 86400 * 2 + 50000), now: now), .inDays(3))
    }

    func testMatchesTheInt32FormulaWhereItDidNotTrap() {
        for _ in 0 ..< 5000 {
            let timestamp = Int32.random(in: 0 ... 2_100_000_000)
            let value = Int32(clamping: now) - timestamp
            let expected: RelativeEntityDate
            if value > 0 {
                if value < 60 {
                    expected = .secondsAgo(value)
                } else if value <= 3600 {
                    expected = .minutesAgo(Int32(clamping: Int64(round(Float(value) / 60))))
                } else if value <= 86400 {
                    expected = .hoursAgo(Int32(clamping: Int64(round(Float(value) / 3600))))
                } else {
                    expected = .daysAgo(Int32(clamping: Int64(round(Float(value) / 86400))))
                }
            } else {
                let value = abs(value)
                if value < 60 {
                    expected = .inSeconds(value)
                } else if value <= 3600 {
                    expected = .inMinutes(Int32(clamping: Int64(round(Float(value) / 60))))
                } else if value <= 86400 {
                    expected = .inHours(Int32(clamping: Int64(round(Float(value) / 3600))))
                } else {
                    expected = .inDays(Int32(clamping: Int64(round(Float(value) / 86400))))
                }
            }
            XCTAssertEqual(relativeEntityDate(timestamp: timestamp, now: now), expected, "\(timestamp)")
        }
    }

    func testServerExtremesDoNotTrap() {
        XCTAssertEqual(relativeEntityDate(timestamp: Int32.min, now: now), .daysAgo(45688))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32.max, now: now), .inDays(4022))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32.max, now: -Int64(Int32.max)), .inDays(49710))
        XCTAssertEqual(relativeEntityDate(timestamp: Int32.min, now: Int64(Int32.max)), .daysAgo(49710))
    }
}
