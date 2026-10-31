import XCTest
import QuartzCore

/// `ChatMessageAccessibilityDateFormatter` replaces a per-layout
/// `DateFormatter.localizedString(from:dateStyle: .medium, timeStyle: .short)` in the VoiceOver label
/// of every chat bubble, so its output must be the same string, byte for byte.
final class ChatMessageAccessibilityDateFormatterTests: XCTestCase {
    private func reference(_ date: Date) -> String {
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    /// Timestamps a chat really shows: epoch-ish, old years, DST edges, midnight/noon, leap day,
    /// the far end of Int32, and a dense sweep across a year.
    private func sampleDates() -> [Date] {
        var timestamps: [Int32] = [
            0, 1, 86_399, 86_400,
            946_684_799, 946_684_800,          // 1999-12-31 23:59:59 / 2000-01-01 UTC
            951_782_400,                        // 2000-02-29
            1_143_334_800, 1_143_338_400,       // 2006-03-26 DST edge (EU)
            1_710_054_000, 1_710_057_600,       // 2024-03-10 DST edge (US)
            1_730_595_600, 1_730_599_200,       // 2024-11-03 DST edge (US)
            1_735_689_600, 1_761_955_200,
            Int32.max - 1, Int32.max
        ]
        var t: Int32 = 1_735_689_600
        for _ in 0 ..< 400 {
            timestamps.append(t)
            t &+= 79_357 // ~22h, walks through every hour and weekday
        }
        return timestamps.map { Date(timeIntervalSince1970: Double($0)) }
    }

    func testMatchesLocalizedStringForEveryDate() {
        let formatter = ChatMessageAccessibilityDateFormatter(notificationCenter: NotificationCenter())
        for date in sampleDates() {
            XCTAssertEqual(formatter.string(from: date), reference(date), "\(date.timeIntervalSince1970)")
        }
    }

    func testSharedInstanceMatchesLocalizedString() {
        for date in sampleDates().prefix(20) {
            XCTAssertEqual(ChatMessageAccessibilityDateFormatter.shared.string(from: date), reference(date))
        }
    }

    /// The configuration is the one `localizedString` uses: styles on a default formatter, which takes
    /// the current locale and default time zone.
    func testConfigurationMatchesADefaultFormatter() {
        let formatter = ChatMessageAccessibilityDateFormatter(notificationCenter: NotificationCenter()).currentFormatter()
        let defaults = DateFormatter()
        XCTAssertEqual(formatter.dateStyle, .medium)
        XCTAssertEqual(formatter.timeStyle, .short)
        XCTAssertEqual(formatter.locale, defaults.locale)
        XCTAssertEqual(formatter.timeZone, defaults.timeZone)
        XCTAssertEqual(formatter.calendar, defaults.calendar)
        XCTAssertEqual(formatter.formattingContext, defaults.formattingContext)
        XCTAssertEqual(formatter.doesRelativeDateFormatting, false)
    }

    func testTheFormatterIsReusedUntilTheLocaleOrTimeZoneChanges() {
        let center = NotificationCenter()
        let formatter = ChatMessageAccessibilityDateFormatter(notificationCenter: center)
        let first = formatter.currentFormatter()
        XCTAssertTrue(formatter.currentFormatter() === first, "the formatter must be cached")

        center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        let afterLocale = formatter.currentFormatter()
        XCTAssertFalse(afterLocale === first, "a locale change must rebuild the formatter")

        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertFalse(formatter.currentFormatter() === afterLocale, "a time zone change must rebuild the formatter")

        let date = Date(timeIntervalSince1970: 1_735_689_600)
        XCTAssertEqual(formatter.string(from: date), reference(date))
    }

    /// Layout queues and the main thread format concurrently, while invalidations come in.
    func testConcurrentUseProducesTheReferenceStrings() {
        let center = NotificationCenter()
        let formatter = ChatMessageAccessibilityDateFormatter(notificationCenter: center)
        let dates = sampleDates()
        let expected = dates.map(reference)
        let mismatches = NSLock()
        var mismatchCount = 0
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for round in 0 ..< 50 {
                for (index, date) in dates.enumerated() where (index + worker) % 4 == 0 {
                    if formatter.string(from: date) != expected[index] {
                        mismatches.lock()
                        mismatchCount += 1
                        mismatches.unlock()
                    }
                }
                if worker == 0 && round % 10 == 0 {
                    center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
                }
            }
        }
        XCTAssertEqual(mismatchCount, 0)
    }

    /// Micro-benchmark: old per-call `localizedString` vs the cached formatter. Prints, never fails.
    func testBenchmark() {
        let formatter = ChatMessageAccessibilityDateFormatter(notificationCenter: NotificationCenter())
        let dates = sampleDates()
        func time(_ body: () -> Void) -> Double {
            var best = Double.infinity
            for _ in 0 ..< 5 {
                let start = CACurrentMediaTime()
                body()
                best = min(best, CACurrentMediaTime() - start)
            }
            return best
        }
        var sink = 0
        let old = time {
            for date in dates { sink &+= DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short).utf8.count }
        }
        let new = time {
            for date in dates { sink &+= formatter.string(from: date).utf8.count }
        }
        let perOld = old / Double(dates.count) * 1e6
        let perNew = new / Double(dates.count) * 1e6
        print("ACCESSIBILITY_DATE_BENCH calls=\(dates.count) localizedString=\(String(format: "%.2f", perOld))us cached=\(String(format: "%.2f", perNew))us sink=\(sink)")
    }
}
