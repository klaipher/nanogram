import Foundation

/// Which memory lines go to the short log (the critical log, written whatever "Log to File" says). With "Log to File"
/// off, which is the TestFlight default, these lines are the only in-app record of memory before a jetsam. The short
/// log keeps about three days in 1 MB files, so the volume stays small: an event line (entering the background, a
/// memory warning) at most once a minute per reason, and a periodic line only while the footprint is above 1 GB, at
/// most once every 10 minutes (144 a day at most).
///
/// `now` is a monotonic time in seconds (`ProcessInfo.systemUptime`); a value behind the last line logs nothing.
public struct MemoryShortLogBudget: Sendable {
    public static let eventInterval: Double = 60.0
    public static let periodicInterval: Double = 600.0
    public static let periodicFootprintThreshold: UInt64 = 1024 * 1024 * 1024

    private var lastEventTimes: [String: Double] = [:]
    private var lastPeriodicTime: Double?

    public init() {
    }

    public mutating func shouldLogEvent(reason: String, now: Double) -> Bool {
        if let last = self.lastEventTimes[reason], now - last < MemoryShortLogBudget.eventInterval {
            return false
        }
        self.lastEventTimes[reason] = now
        return true
    }

    /// `footprint` in bytes, nil when unknown (never logs).
    public mutating func shouldLogPeriodic(footprint: UInt64?, now: Double) -> Bool {
        guard let footprint, footprint > MemoryShortLogBudget.periodicFootprintThreshold else {
            return false
        }
        if let last = self.lastPeriodicTime, now - last < MemoryShortLogBudget.periodicInterval {
            return false
        }
        self.lastPeriodicTime = now
        return true
    }
}

/// One compact memory line for the short log (at most 256 bytes, no user data): the footprint (before and after free
/// heap pages are handed back, for a purge), its peak, the malloc heap, compressed and graphics memory, the headroom
/// left, and the largest malloc zone with its block count. The full picture stays in `MemoryDetailReport`, in the file
/// log.
public struct MemoryShortLogLine: Sendable, Equatable {
    public static let maxZoneNameLength = 32

    public var reason: String
    public var memory: ProcessMemory?
    /// The footprint before `MemoryRelief.returnFreeHeapPages()`, for a purge. "After" is then measured right after
    /// that call: it does not include the Postbox caches, which are cleared later on their own queue.
    public var footprintBefore: UInt64?
    public var headroom: UInt64?
    public var topZone: MallocZoneUsage?

    public init(reason: String, memory: ProcessMemory?, footprintBefore: UInt64? = nil, headroom: UInt64?, topZone: MallocZoneUsage?) {
        self.reason = reason
        self.memory = memory
        self.footprintBefore = footprintBefore
        self.headroom = headroom
        self.topZone = topZone
    }

    /// Reads the headroom and the largest malloc zone now. The zones may take their locks: call it off the main thread.
    public static func collect(reason: String, memory: ProcessMemory?, footprintBefore: UInt64? = nil) -> MemoryShortLogLine {
        return MemoryShortLogLine(
            reason: reason,
            memory: memory,
            footprintBefore: footprintBefore,
            headroom: ProcessMemory.availableHeadroom(),
            topZone: MallocZoneUsage.largest(limit: 1).first
        )
    }

    public var text: String {
        var parts: [String] = []
        switch (self.footprintBefore, self.memory) {
        case let (.some(before), .some(memory)):
            parts.append("fp \(MemoryFormat.megabytes(before)) -> \(MemoryFormat.megabytes(memory.footprint)) after heap-page return")
        case let (.none, .some(memory)):
            parts.append("fp \(MemoryFormat.megabytes(memory.footprint))")
        case let (.some(before), .none):
            parts.append("fp \(MemoryFormat.megabytes(before)) before heap-page return, after unavailable")
        case (.none, .none):
            parts.append("fp unavailable")
        }
        if let memory = self.memory {
            parts.append("peak \(MemoryFormat.megabytes(memory.footprintPeak))")
            parts.append("malloc \(MemoryFormat.megabytes(memory.mallocInUse))")
            parts.append("compr \(MemoryFormat.megabytes(memory.compressed))")
            parts.append("gfx \(MemoryFormat.megabytes(memory.graphics))")
        }
        if let headroom = self.headroom {
            parts.append("headroom \(MemoryFormat.megabytes(headroom))")
        }
        if let zone = self.topZone {
            let name = String(zone.name.prefix(MemoryShortLogLine.maxZoneNameLength))
            parts.append("top \(name) \(MemoryFormat.megabytes(zone.bytes))/\(zone.blocks) blocks")
        }
        return "Memory \(self.reason): " + parts.joined(separator: ", ")
    }
}
