import Foundation

/// One event of the app's own journal.
struct WatchJournalEntry: Codable, Equatable, Sendable {
    var date: Date
    var category: String
    var event: String
    var detail: String?
}

/// A short list of the app's own events (launches, sign-in state, background refreshes, report copies) for the
/// journal.txt part of the iPhone's "Send Report". watchOS keeps the app's log lines only a short time: a launch
/// reported 20 h after it started came back with none at all. The journal is kept in a small file, so it covers this
/// launch and the ones before it.
///
/// Only public facts go in: the category and event are literals, and the detail is text the app already logs with
/// `privacy: .public` (an `AuthState.logDescription`, a build number, an error description). Never message text,
/// chat titles, names, phone numbers or file names. The os `Logger` calls stay as they are; this is not a second log.
///
/// It is written to disk only when `flush()` is called (the app going inactive, the end of a background refresh) and
/// only when something was recorded since the last write, never per event.
final class WatchEventJournal: @unchecked Sendable {
    static let maximumEntries = 200
    static let maximumAge: TimeInterval = 3 * 24 * 60 * 60
    static let maximumDetailLength = 120

    static let shared = WatchEventJournal(fileURL: WatchEventJournal.defaultFileURL())

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let writeQueue = DispatchQueue(label: "org.klaipher.Nanogram.watchkitapp.journal", qos: .utility)
    private let lock = NSLock()
    private var entries: [WatchJournalEntry]
    private var changed = false

    /// `fileURL` nil keeps the journal in memory only.
    init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        self.entries = Self.pruned(Self.load(from: fileURL), now: now())
    }

    /// Application Support/diagnostics/watch-journal.json.
    static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("watch-journal.json")
    }

    /// Adds an event. `detail` must be text that is safe in a public log line.
    func record(_ category: StaticString, _ event: StaticString, detail: String? = nil) {
        let entry = WatchJournalEntry(
            date: now(),
            category: category.description,
            event: event.description,
            detail: detail.map { String($0.prefix(Self.maximumDetailLength)) }
        )
        lock.lock()
        entries.append(entry)
        entries = Self.pruned(entries, now: entry.date)
        changed = true
        lock.unlock()
    }

    func snapshot() -> [WatchJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// The journal as report text, oldest first.
    func text() -> String {
        Self.text(snapshot())
    }

    /// Writes the journal off the calling thread if something was recorded since the last write.
    func flush() {
        guard fileURL != nil else { return }
        writeQueue.async { [self] in
            writeChanges()
        }
    }

    /// `flush()` on the calling thread.
    func flushNow() {
        guard fileURL != nil else { return }
        writeQueue.sync {
            writeChanges()
        }
    }

    /// Returns once every `flush()` queued before it has been written.
    func waitForWrites() {
        writeQueue.sync {}
    }

    static func text(_ entries: [WatchJournalEntry]) -> String {
        guard !entries.isEmpty else { return "(no events recorded)\n" }
        let formatter = ISO8601DateFormatter()
        return entries.map { entry in
            let head = "\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.event)"
            guard let detail = entry.detail else { return head }
            return head + ": " + detail
        }.joined(separator: "\n") + "\n"
    }

    /// Called on `writeQueue` only, so writes land in the order they were asked for.
    private func writeChanges() {
        guard let fileURL else { return }
        lock.lock()
        guard changed else {
            lock.unlock()
            return
        }
        changed = false
        let current = entries
        lock.unlock()
        guard let data = try? JSONEncoder().encode(current) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best effort: the entries stay in memory, and the next record marks them for writing again.
        }
    }

    private static func load(from fileURL: URL?) -> [WatchJournalEntry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([WatchJournalEntry].self, from: data) else {
            return []
        }
        return list
    }

    private static func pruned(_ entries: [WatchJournalEntry], now: Date) -> [WatchJournalEntry] {
        let fresh = entries.filter { now.timeIntervalSince($0.date) <= maximumAge }
        return Array(fresh.suffix(maximumEntries))
    }
}
