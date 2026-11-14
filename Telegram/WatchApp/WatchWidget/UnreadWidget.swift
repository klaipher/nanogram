import SwiftUI
import WidgetKit

struct UnreadEntry: TimelineEntry {
    let date: Date
    /// Nil when the app has not written a summary yet (never opened, or no App Group).
    let snapshot: WatchUnreadSnapshot?
    let relevance: TimelineEntryRelevance?
}

/// Reads the summary the app keeps in the App Group. TDLib never runs in the widget process.
struct UnreadProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> UnreadEntry {
        UnreadEntry(
            date: Date(),
            snapshot: WatchUnreadSnapshot(generatedAt: Date(), totalUnread: 3, topChats: [.init(title: "Chat", unread: 3)]),
            relevance: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadEntry>) -> Void) {
        let entry = currentEntry()
        completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(Self.refreshInterval))))
    }

    private func currentEntry() -> UnreadEntry {
        let snapshot = WatchUnreadSnapshotStore.appGroup().read()
        let relevance = snapshot.flatMap { $0.relevanceScore > 0 ? TimelineEntryRelevance(score: $0.relevanceScore, duration: 60 * 60) : nil }
        return UnreadEntry(date: Date(), snapshot: snapshot, relevance: relevance)
    }
}

struct UnreadWidget: Widget {
    static let kind = "org.klaipher.Nanogram.unread"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UnreadProvider()) { entry in
            UnreadWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Unread")
        .description("Unread messages in Nanogram.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct UnreadWidgetView: View {
    let entry: UnreadEntry

    @Environment(\.widgetFamily) private var family
    /// `.privacy` while the watch is locked: counts stay, chat names go.
    @Environment(\.redactionReasons) private var redactionReasons

    private var total: Int { entry.snapshot?.totalUnread ?? 0 }
    private var badge: String { entry.snapshot?.badgeText ?? "–" }
    private var showsNames: Bool { !redactionReasons.contains(.privacy) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "paperplane.fill").font(.caption2)
                    Text(badge).font(.headline).minimumScaleFactor(0.6)
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(total == 1 ? "1 unread" : "\(total) unread").font(.headline)
                if showsNames, let chats = entry.snapshot?.topChats {
                    ForEach(Array(chats.enumerated()), id: \.offset) { _, chat in
                        Text("\(chat.title)  \(chat.unread)").font(.caption2).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Text(total > 0 ? "\(badge) unread" : "No unread")
        case .accessoryCorner:
            Text(badge)
                .widgetCurvesContent()
                .widgetLabel { Text("Unread") }
        default:
            Text(badge)
        }
    }
}
