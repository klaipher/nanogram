import Foundation

/// Decides which MTProto and Postbox lines reach the short log (`critlog-*.txt`, written in every build, 1 MB per file,
/// 20 files). On a tester's device a file filled in as little as 55 minutes, so the hours before a kill were often
/// gone. Replaying that device's short logs, the rules below drop ~37% of the bytes (MTProto lines as a whole were
/// ~60%, but containers and file parts stay on purpose). Left out of the short log (the full log, when on, still has
/// every one):
///
/// - MTProto `preparing msgsAck (...)` and `preparing ping (...)`: ~22% of the bytes. Containers, file parts and every
///   other request stay, since acks and bad_msg_notification refer to container ids.
/// - `Postbox transaction took ... ms` under 50 ms: ~12%. From 50 ms Postbox also logs the live views of the slow
///   transaction, and both lines stay.
/// - The second and later tag spaces of one hole removal (`MessageHistoryHoleIndexTable: removeInternal`), which
///   differ only in `space:`: up to 17 lines per removal. The first one stays.
/// - `TimeBasedCleanup in-memory size`: ~470 lines a minute during the daily scan. Its start and end lines stay.
///
/// What is left out is counted, and `takeSummary(now:)` gives one line with the counts every `summaryInterval`. That
/// call comes with the next MTProto or Postbox line, so the logger also writes the counts so far with `force` when it
/// flushes (`Logger.flushPendingLogs`: before a suspension, on memory warnings and on termination); after a crash or
/// a kill with no flush the counts of the last interval are missing. `now` comes from `ShortLogFilter.now()`, a clock
/// that keeps running while the device sleeps and does not follow wall-clock changes. Safe to use from any thread.
final class ShortLogFilter: @unchecked Sendable {
    static let shared = ShortLogFilter()

    static let transactionThresholdMilliseconds: Double = 50.0
    static let summaryInterval: Double = 300.0
    /// Postbox removes a hole from every tag space in one loop, so its lines follow one another at once.
    static let holeRepeatWindow: Double = 1.0

    struct Counts: Equatable {
        var msgsAck: Int = 0
        var ping: Int = 0
        var fastTransactions: Int = 0
        var holeSpaces: Int = 0
        var cleanupSizeReports: Int = 0

        var isEmpty: Bool {
            return self == Counts()
        }
    }

    private static let mtProtoPrefix = "[MTProto#"
    private static let msgsAckMarker = " preparing msgsAck ("
    private static let pingMarker = " preparing ping ("
    private static let transactionPrefix = "Postbox transaction took "
    private static let holePrefix = "MessageHistoryHoleIndexTable: removeInternal "
    private static let holeSpaceMarker = " space: "
    private static let holeRangeMarker = " range: "
    private static let cleanupSizePrefix = "TimeBasedCleanup in-memory size: "

    private let lock = NSLock()
    private var countsValue = Counts()
    private var lastSummaryAt: Double?
    private var lastHoleKey: String?
    private var lastHoleAt: Double = 0.0

    init() {
    }

    /// Seconds on a clock that keeps running while the device sleeps and does not step with the wall clock, so a
    /// time change neither holds the summary back nor misstates its interval.
    static func now() -> Double {
        return Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000.0
    }

    /// What has been left out since the last summary.
    var counts: Counts {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.countsValue
    }

    /// Whether an MTProto short-log line goes to the short log.
    func admitMTProto(_ line: String) -> Bool {
        guard line.hasPrefix(ShortLogFilter.mtProtoPrefix) else {
            return true
        }
        let isAck = line.range(of: ShortLogFilter.msgsAckMarker) != nil
        let isPing = !isAck && line.range(of: ShortLogFilter.pingMarker) != nil
        if !isAck && !isPing {
            return true
        }
        self.lock.lock()
        if isAck {
            self.countsValue.msgsAck += 1
        } else {
            self.countsValue.ping += 1
        }
        self.lock.unlock()
        return false
    }

    /// Whether a Postbox line goes to the short log. `now` is any clock in seconds.
    func admitPostbox(_ line: String, now: Double) -> Bool {
        if line.hasPrefix(ShortLogFilter.holePrefix) {
            let key = ShortLogFilter.holeKey(line)
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            if let key, let lastHoleKey = self.lastHoleKey, key == lastHoleKey, now - self.lastHoleAt <= ShortLogFilter.holeRepeatWindow {
                self.lastHoleAt = now
                self.countsValue.holeSpaces += 1
                return false
            }
            self.lastHoleKey = key
            self.lastHoleAt = now
            return true
        }

        var admit = true
        var isFastTransaction = false
        var isCleanupSize = false
        if line.hasPrefix(ShortLogFilter.transactionPrefix) {
            if let milliseconds = ShortLogFilter.transactionMilliseconds(line), milliseconds < ShortLogFilter.transactionThresholdMilliseconds {
                admit = false
                isFastTransaction = true
            }
        } else if line.hasPrefix(ShortLogFilter.cleanupSizePrefix) {
            admit = false
            isCleanupSize = true
        }

        self.lock.lock()
        // Any other line ends a hole removal's run of tag spaces.
        self.lastHoleKey = nil
        if isFastTransaction {
            self.countsValue.fastTransactions += 1
        }
        if isCleanupSize {
            self.countsValue.cleanupSizeReports += 1
        }
        self.lock.unlock()
        return admit
    }

    /// One line with what was left out, once `summaryInterval` has passed since the last call that started an
    /// interval, and only when something was left out. The first call starts the first interval. With `force` the
    /// counts so far are written at once (when the logs are flushed, the process may not run again).
    func takeSummary(now: Double, force: Bool = false) -> String? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let lastSummaryAt = self.lastSummaryAt else {
            self.lastSummaryAt = now
            return nil
        }
        // The clock does not go back; should it ever, the interval starts again instead of waiting for it to catch up.
        guard now >= lastSummaryAt else {
            self.lastSummaryAt = now
            return nil
        }
        let elapsed = now - lastSummaryAt
        if force {
            if self.countsValue.isEmpty {
                return nil
            }
        } else if elapsed < ShortLogFilter.summaryInterval {
            return nil
        }
        self.lastSummaryAt = now
        let counts = self.countsValue
        self.countsValue = Counts()
        if counts.isEmpty {
            return nil
        }
        return ShortLogFilter.summaryLine(counts: counts, elapsed: elapsed)
    }

    private static func summaryLine(counts: Counts, elapsed: Double) -> String {
        return "Short log left out in the last \(String(format: "%.0f", elapsed)) s: msgsAck \(counts.msgsAck), ping \(counts.ping), transactions under \(String(format: "%.0f", ShortLogFilter.transactionThresholdMilliseconds)) ms \(counts.fastTransactions), extra hole spaces \(counts.holeSpaces), cleanup size reports \(counts.cleanupSizeReports)"
    }

    /// The duration in a `Postbox transaction took <ms> ms, from: ...` line, or nil when it is not one.
    static func transactionMilliseconds(_ line: String) -> Double? {
        guard line.hasPrefix(ShortLogFilter.transactionPrefix) else {
            return nil
        }
        let rest = line.dropFirst(ShortLogFilter.transactionPrefix.count)
        guard let end = rest.range(of: " ms") else {
            return nil
        }
        return Double(rest[rest.startIndex ..< end.lowerBound])
    }

    /// A hole removal line without its `space:` part: the same for every tag space of one removal.
    private static func holeKey(_ line: String) -> String? {
        guard let space = line.range(of: ShortLogFilter.holeSpaceMarker), let range = line.range(of: ShortLogFilter.holeRangeMarker, range: space.upperBound ..< line.endIndex) else {
            return nil
        }
        return String(line[line.startIndex ..< space.lowerBound]) + String(line[range.lowerBound ..< line.endIndex])
    }
}
