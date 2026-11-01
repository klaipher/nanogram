import XCTest
import TelegramCore
@testable import TelegramStringFormatting

/// Dates from the server near Int32.min/max must round and subtract without trapping.
final class DateRoundingOverflowTests: XCTestCase {
    func testRoundDateToDaysAtExtremes() {
        // The day of Int32.min (1901-12-13 20:45:52 UTC) starts before Int32.min.
        XCTAssertEqual(roundDateToDays(Int32.min), Int32.min)
        XCTAssertEqual(roundDateToDays(Int32.max), Int32.max - Int32.max % 86400)
        XCTAssertEqual(roundDateToDays(0), 0)
        XCTAssertEqual(roundDateToDays(1_800_000_123), 1_800_000_123 - 1_800_000_123 % 86400)
        XCTAssertEqual(roundDateToDays(-1), -86400)
    }

    /// The gift offer bubble shows `expireDate - now` once `expireDate > now`.
    func testGiftOfferExpirationDifference() {
        XCTAssertEqual(clampedTimestampDifference(Int32.max, -100), Int32.max)
        XCTAssertEqual(clampedTimestampDifference(Int32.max, Int32.min), Int32.max)
        XCTAssertEqual(clampedTimestampDifference(1_800_003_600, 1_800_000_000), 3600)
    }
}
