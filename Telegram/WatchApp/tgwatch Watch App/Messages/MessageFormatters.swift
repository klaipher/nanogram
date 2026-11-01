import Foundation
@preconcurrency import TDShim

/// Renders the body text of a message bubble. Mirrors `chatPreview`'s content labels for
/// non-text content but does not prepend a sender prefix (which is drawn as a separate
/// label above the bubble) and does not handle drafts (which are a chat-list concern only).
///
/// Returns `""` for content this milestone doesn't know how to render. Service messages
/// are handled separately; `messageBody` returns `""` for service content.
func messageBody(_ content: MessageContent) -> String {
    switch content {
    case .messageText(let t):    return t.text.text
    case .messagePhoto(let m):   return m.caption.text
    case .messageVideo(let m):   return m.caption.text
    case .messageVideoNote:      return ""
    case .messageVoiceNote(let m): return m.caption.text
    case .messageAudio(let m):   return m.caption.text
    case .messageSticker:        return ""
    case .messageDocument:       return "Document"
    case .messageLocation:       return ""
    case .messageVenue:          return ""
    case .messageContact:        return "Contact"
    case .messagePoll:           return ""
    default:                     return ""
    }
}

/// True for message content that has no dedicated bubble rendering and should show the
/// "Unsupported message" placeholder. Uses positive classification so TDLib's closed
/// `MessageContent` enum's `default` cleanly captures every unhandled type
/// (animations/GIFs, games, invoices, calls, dice, stories, gifts, expired media, …).
///
/// Service-message content is filtered to `.service` rows upstream (see
/// `serviceLineText`) and never reaches the bubble path, so it is irrelevant here.
/// `messageContact` is treated as supported — it keeps its existing "Contact" text
/// fallback in `messageBody`.
func isUnsupportedContent(_ content: MessageContent) -> Bool {
    switch content {
    case .messageText, .messagePhoto, .messageVideo, .messageVideoNote,
         .messageVoiceNote, .messageAudio, .messageSticker, .messageDocument,
         .messageLocation, .messageVenue, .messageContact, .messagePoll:
        return false
    default:
        return true
    }
}

/// Day separator label between messages from different days.
/// `Today` / `Yesterday` for the boundary days, weekday name for the last 7 days,
/// `MMM d` for older or future dates.
///
/// Pure: takes its `today` and `calendar` so tests are deterministic. The default `locale`
/// uses the user's system locale at runtime; tests pin `en_US` for stable strings.
func daySeparatorLabel(
    for date: Foundation.Date,
    today: Foundation.Date,
    calendar: Calendar,
    locale: Locale = .current
) -> String {
    var labels = DaySeparatorLabels(today: today, calendar: calendar, locale: locale)
    return labels.label(for: date)
}

/// `daySeparatorLabel` for many dates against one `today`: the formatters are made once.
struct DaySeparatorLabels {
    private let todayStart: Foundation.Date
    private let calendar: Calendar
    private let locale: Locale
    private var weekday: DateFormatter?
    private var monthDay: DateFormatter?

    init(today: Foundation.Date, calendar: Calendar, locale: Locale) {
        self.todayStart = calendar.startOfDay(for: today)
        self.calendar = calendar
        self.locale = locale
    }

    mutating func label(for date: Foundation.Date) -> String {
        let dayStart = calendar.startOfDay(for: date)
        let dayDiff = calendar.dateComponents([.day], from: dayStart, to: todayStart).day ?? 0

        if dayDiff == 0 { return "Today" }
        if dayDiff == 1 { return "Yesterday" }
        if dayDiff >= 2 && dayDiff <= 6 {
            let formatter = weekday ?? makeFormatter("EEEE")   // "Sunday", "Monday", …
            weekday = formatter
            return formatter.string(from: date)
        }
        let formatter = monthDay ?? makeFormatter("MMM d")     // "May 5", "Dec 31"
        monthDay = formatter
        return formatter.string(from: date)
    }

    private func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
