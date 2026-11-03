import Foundation

/// Bytes the app writes to disk, counted by who writes them, so a MetricKit disk-write report can be matched to
/// its writers. MetricKit only says how much the process wrote in a day; its call trees count write events, not
/// bytes. Every large writer adds what it wrote here (MediaBox resource files per media type, SQLite WAL pages per
/// database, animation caches, temporary files, logs), and `DiskWriteAccountingReporter` logs the totals once an hour
/// and on entering the background and keeps a per-day ledger next to the logs.
///
/// Counting is a lock and a dictionary update per write call, so it is on in every build. Categories are short
/// dotted names (`mediaBox.video`, `sqlite.postbox/db`, `animationCache`, `tempBox.hls`, `logs`).
public final class DiskWriteAccounting: @unchecked Sendable {
    public static let shared = DiskWriteAccounting()

    private let lock = NSLock()
    private var bytes: [String: Int64] = [:]
    private var writes: [String: Int64] = [:]

    public init() {
    }

    /// Records one write of `bytes` bytes. Zero-byte calls still count as a write event (a file created empty
    /// costs a metadata write).
    public func add(_ category: String, bytes: Int) {
        let value = Int64(max(0, bytes))
        self.lock.lock()
        self.bytes[category, default: 0] += value
        self.writes[category, default: 0] += 1
        self.lock.unlock()
    }

    public func snapshot() -> DiskWriteSnapshot {
        self.lock.lock()
        let result = DiskWriteSnapshot(bytes: self.bytes, writes: self.writes)
        self.lock.unlock()
        return result
    }

    /// Bytes written for one category since launch (tests and assertions).
    public func bytesWritten(_ category: String) -> Int64 {
        self.lock.lock()
        let result = self.bytes[category] ?? 0
        self.lock.unlock()
        return result
    }

    /// Bytes written for every category starting with `prefix` since launch.
    public func bytesWritten(prefix: String) -> Int64 {
        self.lock.lock()
        var result: Int64 = 0
        for (key, value) in self.bytes where key.hasPrefix(prefix) {
            result += value
        }
        self.lock.unlock()
        return result
    }
}

/// MediaBox resource categories by `MediaResourceUserContentType` (TelegramCore; its raw values are stored in the
/// StorageBox database, so they do not change).
public enum DiskWriteCategory {
    public static func mediaBox(contentType: UInt8?) -> String {
        guard let contentType else {
            return "mediaBox.untyped"
        }
        switch contentType {
        case 0:
            return "mediaBox.other"
        case 1:
            return "mediaBox.image"
        case 2:
            return "mediaBox.video"
        case 3:
            return "mediaBox.audio"
        case 4:
            return "mediaBox.file"
        case 6:
            return "mediaBox.sticker"
        case 7:
            return "mediaBox.avatar"
        case 8:
            return "mediaBox.audioVideoMessage"
        case 9:
            return "mediaBox.story"
        default:
            return "mediaBox.type\(contentType)"
        }
    }

    public static let mediaBoxCachedRepresentation = "mediaBox.cachedRepresentation"
    public static let mediaBoxMap = "mediaBox.map"
    public static let animationCache = "animationCache"
    public static let directMediaImageCache = "directMediaImageCache"
    public static let tempBoxHLS = "tempBox.hls"
    public static let logs = "logs"
    public static let spotlightIndex = "spotlightIndex"

    /// SQLite pages a database wrote to its WAL on commit, then copied into the database file on a checkpoint.
    public static func sqliteWal(database: String) -> String {
        return "sqlite.wal." + database
    }

    public static func sqliteCheckpoint(database: String) -> String {
        return "sqlite.checkpoint." + database
    }

    /// A short, stable name for a database from its directory: the last two path components, so the account
    /// database (`…/account-<id>/postbox/db`) reads as `postbox/db` and the media index as `storage/…`.
    public static func databaseName(path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        return components.suffix(2).joined(separator: "/")
    }
}

public struct DiskWriteSnapshot: Sendable, Equatable {
    public var bytes: [String: Int64]
    public var writes: [String: Int64]

    public init(bytes: [String: Int64] = [:], writes: [String: Int64] = [:]) {
        self.bytes = bytes
        self.writes = writes
    }

    public var totalBytes: Int64 {
        return self.bytes.values.reduce(0, +)
    }

    /// What was written after `earlier`. Counters only grow, so a negative difference cannot happen; it is
    /// clamped anyway.
    public func subtracting(_ earlier: DiskWriteSnapshot) -> DiskWriteSnapshot {
        var bytes: [String: Int64] = [:]
        var writes: [String: Int64] = [:]
        for (key, value) in self.bytes {
            let delta = value - (earlier.bytes[key] ?? 0)
            if delta > 0 {
                bytes[key] = delta
            }
        }
        for (key, value) in self.writes {
            let delta = value - (earlier.writes[key] ?? 0)
            if delta > 0 {
                writes[key] = delta
            }
        }
        return DiskWriteSnapshot(bytes: bytes, writes: writes)
    }

    public func adding(_ other: DiskWriteSnapshot) -> DiskWriteSnapshot {
        var result = self
        for (key, value) in other.bytes {
            result.bytes[key, default: 0] += value
        }
        for (key, value) in other.writes {
            result.writes[key, default: 0] += value
        }
        return result
    }

    /// Categories by bytes written, largest first; ties by name.
    public var sortedCategories: [String] {
        let keys = Set(self.bytes.keys).union(self.writes.keys)
        return keys.sorted { lhs, rhs in
            let lhsBytes = self.bytes[lhs] ?? 0
            let rhsBytes = self.bytes[rhs] ?? 0
            if lhsBytes != rhsBytes {
                return lhsBytes > rhsBytes
            }
            return lhs < rhs
        }
    }

    /// `mediaBox.video 812.3 MB (1,204 writes), sqlite.wal.postbox/db 20.1 MB (3,310 writes), …`, at most `limit`
    /// categories, the rest summed as `others`.
    public func formattedCategories(limit: Int = 12) -> String {
        let sorted = self.sortedCategories
        var parts: [String] = []
        for key in sorted.prefix(limit) {
            parts.append("\(key) \(DiskWriteSnapshot.formatBytes(self.bytes[key] ?? 0)) (\(self.writes[key] ?? 0) writes)")
        }
        if sorted.count > limit {
            var otherBytes: Int64 = 0
            var otherWrites: Int64 = 0
            for key in sorted.dropFirst(limit) {
                otherBytes += self.bytes[key] ?? 0
                otherWrites += self.writes[key] ?? 0
            }
            parts.append("others \(DiskWriteSnapshot.formatBytes(otherBytes)) (\(otherWrites) writes)")
        }
        return parts.joined(separator: ", ")
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return oneDecimal(Double(bytes) / (1024.0 * 1024.0)) + " MB"
        } else if bytes >= 1024 {
            return oneDecimal(Double(bytes) / 1024.0) + " KB"
        } else {
            return "\(bytes) B"
        }
    }
}

private func oneDecimal(_ value: Double) -> String {
    let tenths = Int64((value * 10.0).rounded())
    return "\(tenths / 10).\(tenths % 10)"
}
