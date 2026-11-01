import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// `messageRows` runs on every coalesced history update, including each progress tick of a
/// download the chat is tracking.
final class CoreMessageRowsTests: XCTestCase {
    private func messages(count: Int, days: Int) throws -> [CachedMessage] {
        let decoder = CoreFixtures.tdlibDecoder()
        let start = 1_700_000_000
        return try (0..<count).map { i in
            let json = CoreFixtures.messageJSON(id: Int64(1000 + i))
                .replacingOccurrences(of: "\"date\":1700000000", with: "\"date\":\(start + i * (days * 86_400 / count))")
            return CachedMessage(try decoder.decode(Message.self, from: Data(json.utf8)))
        }
    }

    private func rows(_ messages: [CachedMessage], calendar: Calendar) -> [MessageRow] {
        messageRows(
            messages: messages, userNames: [2: "Ann"], chatType: .chatTypePrivate(ChatTypePrivate(userId: 2)),
            chatId: CoreFixtures.chatId, today: Date(timeIntervalSince1970: 1_700_000_000 + 30 * 86_400),
            calendar: calendar, locale: Locale(identifier: "en_US")
        )
    }

    func testDaySeparatorsFollowTheCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        let result = rows(try messages(count: 6, days: 3), calendar: calendar)
        let separators = result.compactMap { row -> DayLabel? in
            if case .daySeparator(let label) = row { return label }
            return nil
        }
        XCTAssertEqual(separators.map(\.key), ["2023-11-15", "2023-11-16", "2023-11-17"])
        XCTAssertEqual(separators.map(\.label), ["Nov 15", "Nov 16", "Nov 17"])
        XCTAssertEqual(result.count, 6 + 3)
    }

    /// The key is a row id: one per local day, whatever the user's calendar, written as the
    /// en_US_POSIX "yyyy-MM-dd" formatter writes a Gregorian date.
    func testDayKeysAreOnePerLocalDayInEveryCalendar() throws {
        let window = try messages(count: 200, days: 800)
        for id in [Calendar.Identifier.gregorian, .buddhist, .japanese, .islamicUmmAlQura, .hebrew, .chinese] {
            var calendar = Calendar(identifier: id)
            calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            let reference = DateFormatter()
            reference.calendar = gregorian
            reference.locale = Locale(identifier: "en_US_POSIX")
            reference.timeZone = calendar.timeZone
            reference.dateFormat = "yyyy-MM-dd"
            var expected: [String] = []
            for message in window {
                let key = reference.string(from: Date(timeIntervalSince1970: TimeInterval(message.date)))
                if key != expected.last { expected.append(key) }
            }
            let keys = rows(window, calendar: calendar).compactMap { row -> String? in
                if case .daySeparator(let label) = row { return label.key }
                return nil
            }
            XCTAssertEqual(keys, expected, "\(id)")
            XCTAssertEqual(Set(keys).count, keys.count, "\(id)")
            let days = Set(window.map { calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.date))) })
            XCTAssertEqual(keys.count, days.count, "\(id)")
        }
    }

    /// Prints the cost; the assertion only catches a gross regression.
    func testBenchmarkProjectionOfALoadedWindow() throws {
        let window = try messages(count: 60, days: 4)
        let calendar = Calendar.current
        _ = rows(window, calendar: calendar)
        let runs = 200
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<runs { _ = rows(window, calendar: calendar) }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(runs) / 1_000
        print("BENCH messageRows 60 messages/4 days: \(String(format: "%.1f", perCall)) us per call")
        XCTAssertLessThan(perCall, 20_000)
    }
}
