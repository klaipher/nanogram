import XCTest
@testable import tgwatch_Watch_App

/// The chat-list timestamp, the day separators and file sizes reuse cached formatters. Their
/// output must stay what a fresh formatter gives for every locale, time zone and calendar.
final class CoreFormatterCacheTests: XCTestCase {
    private let locales = ["en_US", "en_GB", "de_DE", "uk_UA", "ja_JP", "ar_SA"].map(Locale.init(identifier:))
    private let timeZones = ["UTC", "Europe/Kyiv", "America/Los_Angeles", "Asia/Tokyo"].compactMap(TimeZone.init(identifier:))
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func calendars() -> [Calendar] {
        var out: [Calendar] = []
        for id in [Calendar.Identifier.gregorian, .japanese] {
            for locale in locales {
                for tz in timeZones {
                    var c = Calendar(identifier: id)
                    c.locale = locale
                    c.timeZone = tz
                    out.append(c)
                }
            }
        }
        return out
    }

    private func referenceTimestamp(_ unixSeconds: Int, now: Date, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let dayDiff = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = calendar.locale ?? .current
        f.timeZone = calendar.timeZone
        switch dayDiff {
        case ...0: f.dateStyle = .none; f.timeStyle = .short
        case 1: return "Yesterday"
        case 2...6: f.setLocalizedDateFormatFromTemplate("EEE")
        default: f.dateStyle = .short; f.timeStyle = .none
        }
        return f.string(from: date)
    }

    private func referenceDayLabel(_ date: Date, today: Date, calendar: Calendar, locale: Locale) -> String {
        let dayDiff = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: today)).day ?? 0
        if dayDiff == 0 { return "Today" }
        if dayDiff == 1 { return "Yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.dateFormat = (2...6).contains(dayDiff) ? "EEEE" : "MMM d"
        return f.string(from: date)
    }

    private let offsets: [Int] = [-3_600, 0, 3_600, 86_400, 2 * 86_400, 5 * 86_400, 6 * 86_400, 8 * 86_400, 400 * 86_400]

    func testChatListTimestampMatchesAFreshFormatter() {
        for calendar in calendars() {
            for offset in offsets {
                let t = Int(now.timeIntervalSince1970) - offset
                XCTAssertEqual(
                    chatListTimestamp(t, now: now, calendar: calendar),
                    referenceTimestamp(t, now: now, calendar: calendar),
                    "\(calendar.identifier) \(calendar.locale?.identifier ?? "") \(calendar.timeZone.identifier) \(offset)"
                )
            }
        }
    }

    func testDaySeparatorMatchesAFreshFormatter() {
        for calendar in calendars() {
            for locale in [calendar.locale ?? .current, Locale(identifier: "fr_FR")] {
                let labels = DaySeparatorLabels(today: now, calendar: calendar, locale: locale)
                for offset in offsets {
                    let date = now.addingTimeInterval(TimeInterval(-offset))
                    let expected = referenceDayLabel(date, today: now, calendar: calendar, locale: locale)
                    XCTAssertEqual(labels.label(for: date), expected)
                    XCTAssertEqual(daySeparatorLabel(for: date, today: now, calendar: calendar, locale: locale), expected)
                }
            }
        }
    }

    func testFileSizeMatchesAFreshFormatter() {
        for bytes: Int64 in [0, 1, 999, 1_000, 1_536, 52_428_800, 3_000_000_000] {
            let f = ByteCountFormatter()
            f.countStyle = .file
            f.allowsNonnumericFormatting = false
            XCTAssertEqual(formatFileSize(bytes), f.string(fromByteCount: bytes))
        }
    }

    /// A change of locale or time zone gives a new formatter rather than the cached one.
    func testCacheKeysOnLocaleAndTimeZone() {
        var kyiv = Calendar(identifier: .gregorian)
        kyiv.locale = Locale(identifier: "en_US")
        kyiv.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        var tokyo = kyiv
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let t = Int(now.timeIntervalSince1970)
        XCTAssertNotEqual(chatListTimestamp(t, now: now, calendar: kyiv), chatListTimestamp(t, now: now, calendar: tokyo))

        let a = CachedFormatters.date(.shortTime, calendar: kyiv, locale: Locale(identifier: "en_US"))
        let b = CachedFormatters.date(.shortTime, calendar: kyiv, locale: Locale(identifier: "en_US"))
        let c = CachedFormatters.date(.shortTime, calendar: kyiv, locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(a === b)
        XCTAssertFalse(a === c)
    }
}
