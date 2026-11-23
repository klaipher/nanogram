/// How many upload parts (`saveFilePart`) may be in flight at once. Nanogram-only; a pure value type with no
/// networking, so it is driven by tests with a made-up clock (`Tests/UploadPartWindowTests.swift`).
///
/// The window starts at today's fixed value (6 parts under 512 KB, 3 for 512 KB parts) on Wi-Fi or when the network is
/// not known, lower on cellular, grows by one for each clean fast part and halves when a part is slow, retried,
/// stalled or failed (at most once per holdoff). It only decides how many parts are issued at once; it never changes
/// what is sent, and nothing in flight is cancelled when it shrinks.
struct UploadPartWindow {
    enum NetworkClass: String {
        case unknown
        case wifi
        case cellular
    }

    struct Config {
        var partSize: Int
        var network: NetworkClass
        /// The window never exceeds this, whatever the part size (the shared `.main(dc)` pool allows 12).
        var hardCap = 8
        /// The window never holds more than this many bytes (today's 3 x 512 KB).
        var byteBudget = 1_536 * 1024
        var minWindow = 2
        /// A part is fast when it finishes within `fastBase + partSize / fastRate` seconds.
        var fastBase = 1.0
        var fastRate = 256.0 * 1024
        /// A part is slow when it takes longer than this (below the 12 s engine response timeout).
        var slowLimit = 8.0
        /// The window never grows beyond what the measured goodput carries in this many seconds.
        var goodputHorizon = 6.0
        var holdoffRange = 1.0 ... 8.0
    }

    struct Stats: Equatable {
        var parts = 0
        var bytes = 0
        var retries = 0
        var stalls = 0
        var failures = 0
        var decreases = 0
        var minWindow = 0
        var maxWindow = 0
        var startNetwork = NetworkClass.unknown
        var endNetwork = NetworkClass.unknown
    }

    private struct Record {
        var bytes: Int
        var attemptStart: Double
        var inFlightAtStart: Int
        var windowAtStart: Int
        var retried = false
        var stalled = false
    }

    private static let goodputSamplesNeeded = 4
    private static let goodputSamplesKept = 8

    private var config: Config
    private var records: [Int64: Record] = [:]
    private var finishes: [(at: Double, bytes: Int)] = []
    private var ssthresh: Int
    private var creditsTowardGrowth = 0
    private var lastDecreaseAt: Double?
    private var lastHoldoff = 0.0

    private(set) var window: Int
    private(set) var stats: Stats

    /// How many parts the upload may have in flight now.
    var allowedInFlight: Int {
        return self.window
    }

    init(_ config: Config) {
        self.config = config
        let initial = UploadPartWindow.initialWindow(config)
        self.window = initial
        self.ssthresh = UploadPartWindow.maxParts(config)
        var stats = Stats()
        stats.minWindow = initial
        stats.maxWindow = initial
        stats.startNetwork = config.network
        stats.endNetwork = config.network
        self.stats = stats
    }

    // MARK: - Limits

    private static func maxParts(_ config: Config) -> Int {
        let bySize = config.partSize > 0 ? config.byteBudget / config.partSize : config.hardCap
        return max(config.minWindow, min(config.hardCap, bySize))
    }

    private static func cellularInitial(_ config: Config) -> Int {
        let partSize = max(1, config.partSize)
        let wanted = (512 * 1024 + partSize - 1) / partSize
        return min(maxParts(config), max(config.minWindow, wanted))
    }

    private static func initialWindow(_ config: Config) -> Int {
        switch config.network {
        case .cellular:
            return self.cellularInitial(config)
        case .wifi, .unknown:
            let today = config.partSize < 512 * 1024 ? 6 : 3
            return min(self.maxParts(config), today)
        }
    }

    private var maxParts: Int {
        return UploadPartWindow.maxParts(self.config)
    }

    private var fastLimit: Double {
        return self.config.fastBase + Double(self.config.partSize) / self.config.fastRate
    }

    /// The most parts the measured goodput carries in `goodputHorizon` seconds, or nil while there is too little to
    /// tell (growth waits for it). Only stops growth; never shrinks the window.
    private var goodputCap: Int? {
        guard self.finishes.count >= UploadPartWindow.goodputSamplesNeeded, let first = self.finishes.first, let last = self.finishes.last else {
            return nil
        }
        let span = last.at - first.at
        if span <= 0 {
            return nil
        }
        // The first part ended where the span starts, so its bytes are not part of what arrived inside it.
        var bytes = 0
        for sample in self.finishes.dropFirst() {
            bytes += sample.bytes
        }
        let goodput = Double(bytes) / span
        let parts = (goodput * self.config.goodputHorizon / Double(max(1, self.config.partSize))).rounded(.down)
        if !parts.isFinite || parts > Double(self.config.hardCap) {
            return self.config.hardCap
        }
        return max(self.config.minWindow, Int(parts))
    }

    // MARK: - Events

    /// `inFlight` is the number of parts in flight before this one is added.
    mutating func partStarted(id: Int64, bytes: Int, inFlight: Int, at: Double) {
        self.records[id] = Record(bytes: bytes, attemptStart: at, inFlightAtStart: inFlight, windowAtStart: self.window)
    }

    mutating func partFinished(id: Int64, at: Double) {
        guard let record = self.records.removeValue(forKey: id) else {
            return
        }
        self.stats.parts += 1
        self.stats.bytes += record.bytes
        self.finishes.append((at: at, bytes: record.bytes))
        if self.finishes.count > UploadPartWindow.goodputSamplesKept {
            self.finishes.removeFirst(self.finishes.count - UploadPartWindow.goodputSamplesKept)
        }
        if record.stalled {
            // Already answered with a decrease when it stalled; a late finish is neither slow news nor fast.
            return
        }
        let duration = at - record.attemptStart
        if duration > self.config.slowLimit {
            self.decrease(duration: duration, at: at)
        } else if !record.retried && duration < self.fastLimit && record.inFlightAtStart + 1 >= record.windowAtStart {
            self.credit()
        }
    }

    /// A retryable failure of one attempt. The next attempt starts at `resumesAt`, so the back-off is not latency.
    mutating func partRetried(id: Int64, at: Double, resumesAt: Double) {
        self.stats.retries += 1
        var duration = 0.0
        if var record = self.records[id] {
            duration = at - record.attemptStart
            record.retried = true
            record.attemptStart = resumesAt
            self.records[id] = record
        }
        self.decrease(duration: duration, at: at)
    }

    /// The soft first-answer deadline passed. The part is left alone.
    mutating func partStalled(id: Int64, at: Double) {
        guard var record = self.records[id], !record.stalled else {
            return
        }
        record.stalled = true
        self.records[id] = record
        self.stats.stalls += 1
        self.decrease(duration: at - record.attemptStart, at: at)
    }

    mutating func partFailed(id: Int64, at: Double) {
        self.stats.failures += 1
        var duration = 0.0
        if let record = self.records.removeValue(forKey: id) {
            duration = at - record.attemptStart
        }
        self.decrease(duration: duration, at: at)
    }

    mutating func networkChanged(_ network: NetworkClass, at: Double) {
        let previous = self.config.network
        self.config.network = network
        self.stats.endNetwork = network
        if network == .cellular && previous != .cellular {
            self.window = min(self.window, UploadPartWindow.cellularInitial(self.config))
            self.ssthresh = min(self.ssthresh, self.window)
            self.creditsTowardGrowth = 0
            self.noteWindow()
        }
    }

    /// The part size changed (or the upload started over): forget what was measured, keep the totals.
    mutating func restart(partSize: Int, at: Double) {
        self.config.partSize = partSize
        self.records.removeAll()
        self.finishes.removeAll()
        self.creditsTowardGrowth = 0
        self.lastDecreaseAt = nil
        self.lastHoldoff = 0
        self.ssthresh = UploadPartWindow.maxParts(self.config)
        self.window = UploadPartWindow.initialWindow(self.config)
        self.noteWindow()
    }

    // MARK: - Rules

    private mutating func credit() {
        if self.window >= self.maxParts {
            return
        }
        // Too few finished parts to tell the goodput yet: do not grow on a guess.
        guard let cap = self.goodputCap, self.window + 1 <= cap else {
            return
        }
        if self.window < self.ssthresh {
            self.window += 1
        } else {
            self.creditsTowardGrowth += 1
            if self.creditsTowardGrowth >= self.window {
                self.creditsTowardGrowth = 0
                self.window += 1
            }
        }
        self.noteWindow()
    }

    private mutating func decrease(duration: Double, at: Double) {
        if let last = self.lastDecreaseAt, at < last + self.lastHoldoff {
            return
        }
        let range = self.config.holdoffRange
        self.lastHoldoff = min(max(duration, range.lowerBound), range.upperBound)
        self.lastDecreaseAt = at
        self.creditsTowardGrowth = 0
        let reduced = max(self.config.minWindow, self.window / 2)
        if reduced < self.window {
            self.stats.decreases += 1
        }
        self.window = reduced
        self.ssthresh = reduced
        self.noteWindow()
    }

    private mutating func noteWindow() {
        self.stats.minWindow = min(self.stats.minWindow, self.window)
        self.stats.maxWindow = max(self.stats.maxWindow, self.window)
    }
}
