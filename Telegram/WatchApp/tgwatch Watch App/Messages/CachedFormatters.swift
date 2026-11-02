import Foundation

/// Shared formatters. Making a `DateFormatter` costs ~100-200 us (M4), formatting with a made
/// one ~0.4 us, and the chat list and every history projection format on the main thread.
///
/// A formatter is keyed by everything it was configured with (calendar, locale, time zone), so a
/// change of the user's locale or time zone reads a new key and gets a new formatter; nothing has
/// to be invalidated. Formatting with one shared `DateFormatter` from several threads is safe.
enum CachedFormatters {
    enum DateKind: Hashable {
        /// `dateStyle = .none, timeStyle = .short`
        case shortTime
        /// `dateStyle = .short, timeStyle = .none`
        case shortDate
        /// a localized template (`setLocalizedDateFormatFromTemplate`)
        case template(String)
        /// a fixed `dateFormat`
        case format(String)
    }

    private struct DateKey: Hashable {
        let kind: DateKind
        let calendar: Calendar
        let locale: Locale
        let timeZone: TimeZone
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var dates: [DateKey: DateFormatter] = [:]
        var byteCounts: [Locale: ByteCountFormatter] = [:]
    }

    private static let storage = Storage()
    /// Keys only change with the locale or time zone; a cap keeps a long session bounded anyway.
    private static let maxEntries = 64

    static func date(_ kind: DateKind, calendar: Calendar, locale: Locale) -> DateFormatter {
        let key = DateKey(kind: kind, calendar: calendar, locale: locale, timeZone: calendar.timeZone)
        storage.lock.lock()
        defer { storage.lock.unlock() }
        if let formatter = storage.dates[key] { return formatter }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        switch kind {
        case .shortTime:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case .shortDate:
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        case .template(let template):
            formatter.setLocalizedDateFormatFromTemplate(template)
        case .format(let format):
            formatter.dateFormat = format
        }
        if storage.dates.count >= maxEntries { storage.dates.removeAll() }
        storage.dates[key] = formatter
        return formatter
    }

    /// `ByteCountFormatter` with `.file` count style and numeric "Zero KB", for the current locale.
    static func fileSize(locale: Locale = .current) -> ByteCountFormatter {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        if let formatter = storage.byteCounts[locale] { return formatter }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        if storage.byteCounts.count >= maxEntries { storage.byteCounts.removeAll() }
        storage.byteCounts[locale] = formatter
        return formatter
    }
}
