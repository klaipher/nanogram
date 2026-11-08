import Foundation

/// Groups deletes into runs (a held key and its repeats, or quick taps) for one diagnostic log line per run: how many
/// deletes the keyboard delivered, over how long, and how many programmatic text or caret writes the composer made
/// during the run. Reported held deletes that removed one character per hold (2026-11-08) are told apart this way:
/// `count=1` for a held key means the keyboard sent no repeats; `writes>0` means our code touched the text meanwhile.
struct DeleteBurstTracker {
    /// Longer than the keyboard's first repeat delay (~0.5 s), so a held key's first repeat stays in its run.
    static let gap: Double = 0.6

    private var start: Double?

    /// A run has started and has not been finished yet.
    var hasOpenRun: Bool {
        return self.start != nil
    }
    private var last: Double = 0.0
    private var count: Int = 0
    private var writes: Int = 0

    /// Records a delete; returns the previous run's line when this delete starts a new run.
    mutating func recordDelete(at time: Double) -> String? {
        var finished: String?
        if self.start != nil, time - self.last >= DeleteBurstTracker.gap {
            finished = self.summary()
            self.start = nil
        }
        if self.start == nil {
            self.start = time
            self.count = 0
            self.writes = 0
        }
        self.count += 1
        self.last = time
        return finished
    }

    mutating func recordProgrammaticWrite(at time: Double) {
        if self.start != nil, time - self.last < DeleteBurstTracker.gap {
            self.writes += 1
        }
    }

    /// The run's line once it is over (no delete for `gap`); nil while it may still continue or when there is none.
    mutating func finish(at time: Double) -> String? {
        guard self.start != nil, time - self.last >= DeleteBurstTracker.gap else {
            return nil
        }
        let line = self.summary()
        self.start = nil
        return line
    }

    private func summary() -> String {
        let span = Int(((self.last - (self.start ?? self.last)) * 1000.0).rounded())
        return "Composer delete burst: count=\(self.count) spanMs=\(span) writes=\(self.writes)"
    }
}
