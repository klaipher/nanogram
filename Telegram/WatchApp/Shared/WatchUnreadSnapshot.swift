import Foundation

/// The unread summary the watch app writes and the widget extension reads (IOS-WATCH-WIDGET-1).
///
/// Counts and chat titles only, never message text. The widget hides the titles when the system asks it to redact
/// private content (locked watch). Compiled into both the watch app and the widget extension.
struct WatchUnreadSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Chat: Codable, Equatable, Sendable {
        let title: String
        let unread: Int
    }

    var version: Int
    var generatedAt: Date
    /// Unread messages in unmuted chats of the main list.
    var totalUnread: Int
    /// The top unmuted chats with unread messages, in list order.
    var topChats: [Chat]

    init(version: Int = Self.currentVersion, generatedAt: Date, totalUnread: Int, topChats: [Chat]) {
        self.version = version
        self.generatedAt = generatedAt
        self.totalUnread = totalUnread
        self.topChats = topChats
    }

    /// Same content, ignoring when it was generated.
    func hasSameContent(as other: WatchUnreadSnapshot) -> Bool {
        totalUnread == other.totalUnread && topChats == other.topChats
    }

    /// Smart Stack relevance: 0 with nothing unread, rising with the count and capped at 100.
    var relevanceScore: Float {
        totalUnread > 0 ? min(100, 30 + Float(totalUnread) * 5) : 0
    }

    /// "7", or "99+" so the count fits a circular complication.
    var badgeText: String {
        totalUnread > 99 ? "99+" : String(max(0, totalUnread))
    }
}

/// One JSON file in the shared App Group container. Without the App Group entitlement the container does not exist and
/// every call is a quiet no-op, so the app can ship this code before the portal setup is done.
struct WatchUnreadSnapshotStore: Sendable {
    static let appGroupIdentifier = "group.org.klaipher.Nanogram.watch"
    static let fileName = "unread-snapshot.json"

    let directory: URL?

    init(directory: URL?) {
        self.directory = directory
    }

    /// The store in the App Group container; its directory is nil when the app has no such group.
    static func appGroup(fileManager: FileManager = .default) -> WatchUnreadSnapshotStore {
        WatchUnreadSnapshotStore(directory: fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier))
    }

    var isAvailable: Bool { directory != nil }

    private var fileURL: URL? {
        directory?.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    @discardableResult
    func write(_ snapshot: WatchUnreadSnapshot) -> Bool {
        guard let fileURL else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Nil when there is no file, it is unreadable, or it was written by a newer format.
    func read() -> WatchUnreadSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(WatchUnreadSnapshot.self, from: data),
              snapshot.version <= WatchUnreadSnapshot.currentVersion else { return nil }
        return snapshot
    }
}
