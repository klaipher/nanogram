import Foundation
import WidgetKit

/// A chat reduced to what the unread summary needs.
struct UnreadChatInput: Equatable {
    let title: String
    let unread: Int
    let isMuted: Bool
}

enum WatchUnreadSnapshotBuilder {
    static let maximumTitleLength = 40

    /// `ordered` is the main list in display order. Muted chats and chats without unread messages are left out,
    /// like the badge of the official app.
    static func make(ordered: [UnreadChatInput], now: Date, topLimit: Int = 2) -> WatchUnreadSnapshot {
        let unread = ordered.filter { !$0.isMuted && $0.unread > 0 }
        let total = unread.reduce(0) { $0 + $1.unread }
        let top = unread.prefix(max(0, topLimit)).map {
            WatchUnreadSnapshot.Chat(title: String($0.title.prefix(maximumTitleLength)), unread: $0.unread)
        }
        return WatchUnreadSnapshot(generatedAt: now, totalUnread: total, topChats: top)
    }
}

/// Writes the unread summary to the App Group and asks WidgetKit to reload (IOS-WATCH-WIDGET-1). Writes are skipped
/// when nothing changed and limited to one per `minimumInterval`, because widget reloads count against a budget.
/// Everything is behind `WatchFeature.widgetSnapshot` and does nothing without the App Group container.
@MainActor
final class WidgetSnapshotPublisher {
    private let store: WatchUnreadSnapshotStore
    private let reload: () -> Void
    private let minimumInterval: TimeInterval
    private let coalesceDelay: Duration
    private let now: () -> Date
    private var lastWritten: WatchUnreadSnapshot?
    private var lastWriteDate: Date?
    private var pending: Task<Void, Never>?

    init(
        store: WatchUnreadSnapshotStore,
        reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        minimumInterval: TimeInterval = 15,
        coalesceDelay: Duration = .seconds(3),
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.reload = reload
        self.minimumInterval = minimumInterval
        self.coalesceDelay = coalesceDelay
        self.now = now
    }

    var isAvailable: Bool { store.isAvailable }

    /// Writes `snapshot` unless it matches the last one or the last write was too recent. True when written.
    @discardableResult
    func publish(_ snapshot: WatchUnreadSnapshot, force: Bool = false) -> Bool {
        guard store.isAvailable else { return false }
        if let lastWritten, lastWritten.hasSameContent(as: snapshot) { return false }
        if !force, let lastWriteDate, now().timeIntervalSince(lastWriteDate) < minimumInterval { return false }
        guard store.write(snapshot) else { return false }
        lastWritten = snapshot
        lastWriteDate = now()
        reload()
        return true
    }

    /// Chat-list projections arrive in bursts; one snapshot is built a few seconds after the first of a burst.
    func requestPublish(inputs: @escaping @MainActor () -> [UnreadChatInput]) {
        guard store.isAvailable, pending == nil else { return }
        pending = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.coalesceDelay)
            guard !Task.isCancelled else { return }
            self.pending = nil
            self.publish(WatchUnreadSnapshotBuilder.make(ordered: inputs(), now: self.now()))
        }
    }

    /// Builds and writes a snapshot now (background refresh), bypassing the interval but not the same-content check.
    func publishNow(inputs: [UnreadChatInput]) {
        publish(WatchUnreadSnapshotBuilder.make(ordered: inputs, now: now()), force: true)
    }
}
