public import Foundation

/// Per-day totals of `DiskWriteAccounting`, kept across launches so a day's totals can be set beside that day's
/// MetricKit `cumulativeLogicalWrites`. Stored as a small JSON file (a few KB) and rewritten only when the reporter
/// reports, at most once an hour plus once per background entry.
public struct DiskWriteLedger: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var bytes: [String: Int64]
        public var writes: [String: Int64]

        public init(bytes: [String: Int64] = [:], writes: [String: Int64] = [:]) {
            self.bytes = bytes
            self.writes = writes
        }

        public var snapshot: DiskWriteSnapshot {
            return DiskWriteSnapshot(bytes: self.bytes, writes: self.writes)
        }
    }

    public static let keptDays = 14

    /// Keyed by local calendar day, `yyyy-MM-dd`.
    public var days: [String: Day]

    public init(days: [String: Day] = [:]) {
        self.days = days
    }

    public mutating func add(_ delta: DiskWriteSnapshot, day: String) {
        if delta.bytes.isEmpty && delta.writes.isEmpty {
            return
        }
        let updated = (self.days[day]?.snapshot ?? DiskWriteSnapshot()).adding(delta)
        self.days[day] = Day(bytes: updated.bytes, writes: updated.writes)
        if self.days.count > DiskWriteLedger.keptDays {
            for key in self.days.keys.sorted().prefix(self.days.count - DiskWriteLedger.keptDays) {
                self.days.removeValue(forKey: key)
            }
        }
    }

    public static func load(path: String) -> DiskWriteLedger {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let ledger = try? JSONDecoder().decode(DiskWriteLedger.self, from: data) else {
            return DiskWriteLedger()
        }
        return ledger
    }

    public func save(path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            return
        }
        let _ = try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// One line per day, newest first: `2026-11-03: 1,204.3 MB; mediaBox.video 812.3 MB (…), …`.
    public func formattedDays(limit: Int = 12) -> String {
        var lines: [String] = []
        for key in self.days.keys.sorted(by: >) {
            guard let day = self.days[key] else {
                continue
            }
            let snapshot = day.snapshot
            lines.append("\(key): \(DiskWriteSnapshot.formatBytes(snapshot.totalBytes)); \(snapshot.formattedCategories(limit: limit))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Turns the running counters into a log line and the per-day ledger. The app calls `report(reason:)` once an hour
/// and when it enters the background; each call accounts only what was written since the previous one.
public final class DiskWriteAccountingReporter: @unchecked Sendable {
    private let accounting: DiskWriteAccounting
    private let ledgerPath: String?
    private let now: @Sendable () -> Date
    private let launchDate: Date
    private let lock = NSLock()
    private var lastSnapshot = DiskWriteSnapshot()
    private var lastReportDate: Date
    private var ledger: DiskWriteLedger?

    public init(accounting: DiskWriteAccounting = .shared, ledgerPath: String?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.accounting = accounting
        self.ledgerPath = ledgerPath
        self.now = now
        self.launchDate = now()
        self.lastReportDate = self.launchDate
    }

    public static func dayKey(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        return "\(components.year ?? 0)-\(twoDigits(components.month ?? 0))-\(twoDigits(components.day ?? 0))"
    }

    /// Accounts what was written since the last report, adds it to today's ledger entry and returns the log line.
    @discardableResult
    public func report(reason: String) -> String {
        let current = self.accounting.snapshot()
        let date = self.now()

        self.lock.lock()
        let delta = current.subtracting(self.lastSnapshot)
        let interval = date.timeIntervalSince(self.lastReportDate)
        self.lastSnapshot = current
        self.lastReportDate = date

        var ledger = self.ledger ?? self.ledgerPath.map(DiskWriteLedger.load(path:)) ?? DiskWriteLedger()
        let dayKey = DiskWriteAccountingReporter.dayKey(date)
        ledger.add(delta, day: dayKey)
        self.ledger = ledger
        if let ledgerPath = self.ledgerPath, !(delta.bytes.isEmpty && delta.writes.isEmpty) {
            ledger.save(path: ledgerPath)
        }
        let today = ledger.days[dayKey]?.snapshot ?? DiskWriteSnapshot()
        self.lock.unlock()

        let sinceLaunch = date.timeIntervalSince(self.launchDate)
        return "Disk writes (\(reason)): \(DiskWriteSnapshot.formatBytes(delta.totalBytes)) in \(Int(interval / 60.0)) min; \(delta.formattedCategories()). Since launch \(DiskWriteSnapshot.formatBytes(current.totalBytes)) in \(Int(sinceLaunch / 60.0)) min; today \(DiskWriteSnapshot.formatBytes(today.totalBytes))"
    }

    /// `report(reason:)` before iOS may suspend the app, which can then kill it without any later report (a process
    /// launched in the background by a push never gets an hourly or foreground one). Reports only when at least
    /// `minimumBytes` were written since the last report, so the ledger is not rewritten on every short wakeup; a
    /// smaller amount stays for the next report. Nil when nothing was reported.
    @discardableResult
    public func reportIfPending(atLeast minimumBytes: Int64, reason: String) -> String? {
        let current = self.accounting.snapshot()
        self.lock.lock()
        let pendingBytes = current.subtracting(self.lastSnapshot).totalBytes
        self.lock.unlock()
        if pendingBytes < minimumBytes {
            return nil
        }
        return self.report(reason: reason)
    }

    /// The ledger as of the last report, plus what was written since (for Debug Settings and log exports).
    public func summary() -> String {
        let current = self.accounting.snapshot()
        self.lock.lock()
        var ledger = self.ledger ?? self.ledgerPath.map(DiskWriteLedger.load(path:)) ?? DiskWriteLedger()
        ledger.add(current.subtracting(self.lastSnapshot), day: DiskWriteAccountingReporter.dayKey(self.now()))
        self.lock.unlock()
        return "Since launch: \(DiskWriteSnapshot.formatBytes(current.totalBytes)); \(current.formattedCategories(limit: 20))\n\nBy day:\n\(ledger.formattedDays(limit: 20))"
    }
}

private func twoDigits(_ value: Int) -> String {
    return value < 10 ? "0\(value)" : "\(value)"
}

/// The app's reporter, installed once at launch (AppDelegate) and read by Debug Settings and the log exports.
public enum DiskWriteAccountingReporting {
    private final class Holder: @unchecked Sendable {
        let lock = NSLock()
        var reporter: DiskWriteAccountingReporter?
        var ledgerPath: String?
    }

    private static let holder = Holder()

    @discardableResult
    public static func install(ledgerPath: String) -> DiskWriteAccountingReporter {
        let holder = DiskWriteAccountingReporting.holder
        holder.lock.lock()
        defer {
            holder.lock.unlock()
        }
        if let reporter = holder.reporter {
            return reporter
        }
        let reporter = DiskWriteAccountingReporter(ledgerPath: ledgerPath)
        holder.reporter = reporter
        holder.ledgerPath = ledgerPath
        return reporter
    }

    public static var current: DiskWriteAccountingReporter? {
        let holder = DiskWriteAccountingReporting.holder
        holder.lock.lock()
        defer {
            holder.lock.unlock()
        }
        return holder.reporter
    }

    /// Where the per-day ledger is kept (a JSON file), for the MetricKit export.
    public static var ledgerPath: String? {
        let holder = DiskWriteAccountingReporting.holder
        holder.lock.lock()
        defer {
            holder.lock.unlock()
        }
        return holder.ledgerPath
    }
}
