import Foundation

/// Decides whether a per-frame "plan the rows ahead" call can be skipped because nothing it reads has changed since the last
/// call that ran. Planning builds a key, layout params and a retain list for every candidate row, which on a fling is the same
/// work 60-120 times a second for an unchanged loaded range.
///
/// The signature holds everything the plan is computed from: the loaded range, the travel direction, the content width, the
/// pass-through flags, and a revision of the row entries (bumped whenever they are replaced). State the signature cannot see
/// (the interaction epoch, a prepared row's time to live, a job that failed) is covered by `maximumSkipInterval`: the plan
/// is re-run at least that often, so a skipped frame can delay a re-plan but never lose one.
///
/// Main thread only.
public struct ChatRowPrefetchPlanGate {
    public struct Signature: Equatable {
        public var first: Int
        public var last: Int
        public var direction: Int
        public var width: Double
        public var entriesRevision: UInt64
        public var prefersSynchronousLoads: Bool

        public init(first: Int, last: Int, direction: Int, width: Double, entriesRevision: UInt64, prefersSynchronousLoads: Bool) {
            self.first = first
            self.last = last
            self.direction = direction
            self.width = width
            self.entriesRevision = entriesRevision
            self.prefersSynchronousLoads = prefersSynchronousLoads
        }
    }

    /// Longest time an unchanged signature may suppress planning.
    public static let maximumSkipInterval: Double = 0.25

    private var lastSignature: Signature?
    private var lastRunTime: Double = 0.0
    public private(set) var skippedCount: Int = 0

    public init() {
    }

    /// True if the plan must run now; records the run. False if the last run covered the same inputs a moment ago.
    public mutating func shouldRun(signature: Signature, now: Double) -> Bool {
        if let lastSignature = self.lastSignature, lastSignature == signature, now >= self.lastRunTime, now - self.lastRunTime < ChatRowPrefetchPlanGate.maximumSkipInterval {
            self.skippedCount += 1
            return false
        }
        self.lastSignature = signature
        self.lastRunTime = now
        return true
    }

    /// Forget the last run (the prefetcher was emptied, so the next call must plan again).
    public mutating func reset() {
        self.lastSignature = nil
    }
}
