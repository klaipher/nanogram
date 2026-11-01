import XCTest
import TelegramCore
import TelegramPresentationData
@testable import TelegramStringFormatting

// Build 202611011645 crashed at every launch on Int32 overflow in presence math (Int32.max is
// "online with no end"). These pin the same class elsewhere: any server Int32 or Int64 must
// format without trapping.
final class ServerValueOverflowTests: XCTestCase {
    private let now: Int32 = 1_800_000_000

    func testClampedTimestampDifference() {
        XCTAssertEqual(clampedTimestampDifference(100, 30), 70)
        XCTAssertEqual(clampedTimestampDifference(30, 100), -70)
        XCTAssertEqual(clampedTimestampDifference(now, Int32.min), Int32.max)
        XCTAssertEqual(clampedTimestampDifference(Int32.min, now), Int32.min)
        XCTAssertEqual(clampedTimestampDifference(Int32.max, -1), Int32.max)
    }

    func testRecentlyWithMaximumLastActivity() {
        // lastActivity is a message date; a date near Int32.max overflowed `lastActivity + 30`.
        let presence = EnginePeer.Presence(status: .recently(isHidden: false), lastActivity: Int32.max)
        guard case let .online(at) = relativeUserPresenceStatus(presence, relativeTo: now) else {
            return XCTFail("expected online")
        }
        XCTAssertEqual(at, Int32.max)
        XCTAssertEqual(userPresenceActiveUntil(lastActivity: Int32.max - 10), Int32.max)
        XCTAssertEqual(userPresenceActiveUntil(lastActivity: 100), 130)

        let timeout = userPresenceStringRefreshTimeout(TelegramUserPresence(status: .recently(isHidden: false), lastActivity: Int32.max), relativeTo: now)
        XCTAssertEqual(timeout, Double(Int64(Int32.max) - Int64(now) + 1))
    }

    func testPresentAtExtremes() {
        XCTAssertEqual(userPresenceStringRefreshTimeout(TelegramUserPresence(status: .present(until: Int32.min), lastActivity: 0), relativeTo: now), Double.infinity)
        XCTAssertEqual(userPresenceStringRefreshTimeout(TelegramUserPresence(status: .present(until: Int32.max), lastActivity: 0), relativeTo: now), Double(Int32.max - now))
        XCTAssertEqual(userPresenceStringRefreshTimeout(TelegramUserPresence(status: .present(until: Int32.max), lastActivity: 0), relativeTo: -1), Double(Int64(Int32.max) + 1))
        // Ordinary values are unchanged.
        XCTAssertEqual(userPresenceStringRefreshTimeout(TelegramUserPresence(status: .present(until: now - 10), lastActivity: 0), relativeTo: now), 21.0)
        XCTAssertEqual(userPresenceStringRefreshTimeout(TelegramUserPresence(status: .present(until: now - 125), lastActivity: 0), relativeTo: now), 6.0)
    }

    func testFormattedNumberAtExtremes() {
        XCTAssertEqual(presentationStringsFormattedNumber(Int32.min, " "), "-2 147 483 648")
        XCTAssertEqual(presentationStringsFormattedNumber(Int32.max, " "), "2 147 483 647")
        XCTAssertEqual(presentationStringsFormattedNumber(Int64.min, ","), "-9,223,372,036,854,775,808")
        XCTAssertEqual(presentationStringsFormattedNumber(Int64.min), "-9223372036854775808")
        // Stars amounts are Int64 on the wire; Int32(value) trapped above Int32.max.
        XCTAssertEqual(presentationStringsFormattedNumber(StarsAmount(value: Int64(Int32.max) + 1, nanos: 0), " "), "2 147 483 648")
        XCTAssertEqual(presentationStringsFormattedNumber(StarsAmount(value: Int64.min, nanos: 0), " "), "-9 223 372 036 854 775 808")
        // Ordinary values are unchanged.
        XCTAssertEqual(presentationStringsFormattedNumber(Int32(999), " "), "999")
        XCTAssertEqual(presentationStringsFormattedNumber(Int32(1234), " "), "1 234")
        XCTAssertEqual(presentationStringsFormattedNumber(Int32(-1234567), " "), "-1 234 567")
        XCTAssertEqual(presentationStringsFormattedNumber(Int64(123456), ","), "123,456")
        XCTAssertEqual(presentationStringsFormattedNumber(StarsAmount(value: 1500, nanos: 0), " "), "1 500")
    }
}
