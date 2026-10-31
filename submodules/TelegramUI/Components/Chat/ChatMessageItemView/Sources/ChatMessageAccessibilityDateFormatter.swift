import Foundation

/// The date line of a message's VoiceOver label, formatted exactly as
/// `DateFormatter.localizedString(from:dateStyle: .medium, timeStyle: .short)` formats it, without
/// building a new `DateFormatter` for every bubble layout.
///
/// `localizedString` creates and configures a fresh formatter on each call — a default-configured
/// `DateFormatter` (current locale, default time zone) with the two styles set — and
/// `ChatMessageAccessibilityData` is built on every bubble layout, so that construction showed up as
/// main-thread time in chat scrolling. This keeps one formatter with the same configuration and drops
/// it when the inputs a default formatter captures at creation can change: the current locale
/// (language, region, calendar, 12/24-hour setting — `NSLocale.currentLocaleDidChangeNotification`)
/// and the system time zone (`NSSystemTimeZoneDidChange`). The next call then builds a new one, so
/// the produced strings stay those `localizedString` would produce.
///
/// Called from the chat's layout queues and from the main thread. Formatting with a shared
/// `DateFormatter` is thread-safe (iOS 7+, 64-bit); the lock only guards creating and replacing it.
final class ChatMessageAccessibilityDateFormatter {
    static let shared = ChatMessageAccessibilityDateFormatter()

    private let lock = NSLock()
    private var formatter: DateFormatter?
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        for name in [NSLocale.currentLocaleDidChangeNotification, Notification.Name.NSSystemTimeZoneDidChange] {
            self.observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: nil, using: { [weak self] _ in
                self?.invalidate()
            }))
        }
    }

    deinit {
        for observer in self.observers {
            self.notificationCenter.removeObserver(observer)
        }
    }

    func string(from date: Date) -> String {
        return self.currentFormatter().string(from: date)
    }

    func invalidate() {
        self.lock.lock()
        self.formatter = nil
        self.lock.unlock()
    }

    /// The formatter in use (internal for tests).
    func currentFormatter() -> DateFormatter {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let formatter = self.formatter {
            return formatter
        }
        // Configured exactly as `+[NSDateFormatter localizedStringFromDate:dateStyle:timeStyle:]`
        // configures its throwaway formatter: defaults, then the two styles.
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        self.formatter = formatter
        return formatter
    }
}
