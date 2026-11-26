import Foundation

/// Bounds the diagnostic lines that also go to the always-on short log (`Logger.shortLog`, the critlog files a report
/// carries even with Log to File off). That log is small and already rotates every few hours, so a diagnostic that
/// misbehaves must not crowd it: at most one line per `interval` for each key, and at most `maxLinesPerWindow` lines per
/// `window` in all. Pure: the caller passes the time.
public struct DiagnosticShortLogBudget {
    public let interval: Double
    public let maxLinesPerWindow: Int
    public let window: Double
    private var lastByKey: [String: Double] = [:]
    private var windowStart: Double?
    private var linesInWindow: Int = 0

    /// Distinct keys remembered at most; past it the per-key memory starts over (keys are kinds of line, not values).
    private static let maxRememberedKeys = 64

    public init(interval: Double, maxLinesPerWindow: Int, window: Double) {
        self.interval = interval
        self.maxLinesPerWindow = maxLinesPerWindow
        self.window = window
    }

    /// Whether a line with `key` may be written at `now` (seconds, any monotonic-enough clock); counts it if so.
    /// A clock that went backwards starts the window and the key over rather than silencing the log.
    public mutating func allow(key: String, now: Double) -> Bool {
        let windowIsCurrent = self.windowStart.map { now >= $0 && now - $0 < self.window } ?? false
        if !windowIsCurrent {
            self.windowStart = now
            self.linesInWindow = 0
        }
        if self.linesInWindow >= self.maxLinesPerWindow {
            return false
        }
        if let last = self.lastByKey[key], now >= last, now - last < self.interval {
            return false
        }
        if self.lastByKey[key] == nil && self.lastByKey.count >= DiagnosticShortLogBudget.maxRememberedKeys {
            self.lastByKey.removeAll()
        }
        self.lastByKey[key] = now
        self.linesInWindow += 1
        return true
    }

    /// `line` cut to at most `maxBytes` UTF-8 bytes, ending in "..." when cut; never splits a character.
    public static func trimmed(_ line: String, maxBytes: Int) -> String {
        if line.utf8.count <= maxBytes {
            return line
        }
        let marker = "..."
        let limit = max(0, maxBytes - marker.utf8.count)
        var result = ""
        var bytes = 0
        for character in line {
            let count = character.utf8.count
            if bytes + count > limit {
                break
            }
            result.append(character)
            bytes += count
        }
        return result + marker
    }
}

/// A `DiagnosticShortLogBudget` shared between threads, read with the wall clock by the caller.
public final class DiagnosticShortLogGate: @unchecked Sendable {
    private let lock = NSLock()
    private var budget: DiagnosticShortLogBudget

    public init(interval: Double, maxLinesPerWindow: Int, window: Double) {
        self.budget = DiagnosticShortLogBudget(interval: interval, maxLinesPerWindow: maxLinesPerWindow, window: window)
    }

    public func allow(key: String, now: Double) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.budget.allow(key: key, now: now)
    }
}
