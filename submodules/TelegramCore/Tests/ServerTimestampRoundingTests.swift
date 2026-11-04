import XCTest
@testable import TelegramCore

/// The chat date headers and the call list group messages by local day with
/// `(timestamp + timezoneOffset) / day * day`. Message dates come from the server, and in Int32
/// that sum trapped for a date within the offset of Int32.max (or of Int32.min).
final class ServerTimestampRoundingTests: XCTestCase {
    private let day: Int32 = 24 * 60 * 60

    private func int32Formula(_ timestamp: Int32, _ offset: Int32) -> Int32 {
        return ((timestamp + offset) / self.day) * self.day
    }

    func testOrdinaryDatesMatchTheInt32Formula() {
        let offsets: [Int32] = [0, 3600, -3600, 50400, -43200, 19800]
        let timestamps: [Int32] = [0, 1, 86399, 86400, 1_700_000_000, 1_800_000_123, -1, -86401, 2_000_000_000]
        for offset in offsets {
            for timestamp in timestamps {
                XCTAssertEqual(timestampRoundedToGranularity(timestamp, offset: offset, granularity: self.day), self.int32Formula(timestamp, offset), "\(timestamp) \(offset)")
            }
        }
        for _ in 0 ..< 10_000 {
            let timestamp = Int32.random(in: -2_000_000_000 ... 2_100_000_000)
            let offset = Int32.random(in: -43200 ... 50400)
            XCTAssertEqual(timestampRoundedToGranularity(timestamp, offset: offset, granularity: self.day), self.int32Formula(timestamp, offset))
        }
    }

    func testServerExtremesDoNotTrap() {
        // In UTC+1 the old guard (`timestamp >= Int32.max - 1000`) left these to `timestamp + 3600`.
        // The sum leaves Int32, the rounded day is back inside it.
        XCTAssertEqual(timestampRoundedToGranularity(2_147_482_000, offset: 3600, granularity: self.day), 2_147_472_000)
        XCTAssertEqual(timestampRoundedToGranularity(Int32.max, offset: 50400, granularity: self.day), 2_147_472_000)
        XCTAssertEqual(timestampRoundedToGranularity(Int32.min, offset: -43200, granularity: self.day), -2_147_472_000)
        XCTAssertEqual(timestampRoundedToGranularity(Int32.min, offset: 0, granularity: self.day), (Int32.min / self.day) * self.day)
        XCTAssertEqual(timestampRoundedToGranularity(Int32.max, offset: 0, granularity: self.day), (Int32.max / self.day) * self.day)
        XCTAssertEqual(timestampRoundedToGranularity(Int32.max, offset: Int32.max, granularity: self.day), Int32.max)
        XCTAssertEqual(timestampRoundedToGranularity(Int32.min, offset: Int32.min, granularity: self.day), Int32.min)
        XCTAssertEqual(timestampRoundedToGranularity(123, offset: 0, granularity: 0), 123)
    }
}
