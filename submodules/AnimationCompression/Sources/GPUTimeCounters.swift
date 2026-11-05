import Foundation

/// How much GPU time the sticker encoder and renderer command buffers took, and how many did not complete. Counted
/// per command buffer (`gpuEndTime - gpuStartTime`) and reported in one line at most once a minute, only when
/// something ran since the last line. Nothing in it is user data.
public final class GPUTimeCounters: @unchecked Sendable {
    public enum Kind: Int, CaseIterable {
        case encode
        case render

        var name: String {
            switch self {
            case .encode:
                return "encode"
            case .render:
                return "render"
            }
        }
    }

    public struct Totals: Equatable {
        public var buffers = 0
        public var failures = 0
        public var gpuSeconds = 0.0
        public var maxGpuSeconds = 0.0

        public init(buffers: Int = 0, failures: Int = 0, gpuSeconds: Double = 0.0, maxGpuSeconds: Double = 0.0) {
            self.buffers = buffers
            self.failures = failures
            self.gpuSeconds = gpuSeconds
            self.maxGpuSeconds = maxGpuSeconds
        }
    }

    public static let reportInterval: Double = 60.0
    public static let shared = GPUTimeCounters()

    private let lock = NSLock()
    private var totals: [Kind: Totals] = [:]
    private var reported: [Kind: Totals] = [:]
    private var lastReportTime: Double?
    private var reporter: (@Sendable (String) -> Void)?

    public init() {
    }

    /// Called with a line at most once a minute. The app logs it.
    public func setReporter(_ reporter: (@Sendable (String) -> Void)?) {
        self.lock.lock()
        self.reporter = reporter
        self.lock.unlock()
    }

    public func snapshot(_ kind: Kind) -> Totals {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.totals[kind] ?? Totals()
    }

    /// `gpuSeconds` is nil for a buffer that did not complete (or has no valid times).
    public func record(_ kind: Kind, gpuSeconds: Double?, now: Double = Date().timeIntervalSince1970) {
        self.lock.lock()
        var value = self.totals[kind] ?? Totals()
        value.buffers += 1
        if let gpuSeconds, gpuSeconds.isFinite, gpuSeconds >= 0.0 {
            value.gpuSeconds += gpuSeconds
            value.maxGpuSeconds = max(value.maxGpuSeconds, gpuSeconds)
        } else {
            value.failures += 1
        }
        self.totals[kind] = value
        let reporter = self.reporter
        let line = self.takeReportLocked(now: now)
        self.lock.unlock()
        if let reporter, let line {
            reporter(line)
        }
    }

    /// The line to log when a minute passed since the last one and a buffer ran since then.
    public func takeReport(now: Double) -> String? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.takeReportLocked(now: now)
    }

    private func takeReportLocked(now: Double) -> String? {
        if self.totals == self.reported {
            return nil
        }
        if let lastReportTime = self.lastReportTime {
            let elapsed = now - lastReportTime
            // A clock set backwards must not silence the report for good.
            if elapsed >= 0.0 && elapsed < GPUTimeCounters.reportInterval {
                return nil
            }
        }
        var parts: [String] = []
        for kind in Kind.allCases {
            let total = self.totals[kind] ?? Totals()
            let before = self.reported[kind] ?? Totals()
            let buffers = total.buffers - before.buffers
            if buffers <= 0 {
                continue
            }
            let seconds = total.gpuSeconds - before.gpuSeconds
            parts.append("\(kind.name) buffers=\(buffers) failed=\(total.failures - before.failures) gpuMs=\(Int((seconds * 1000.0).rounded())) maxMs=\(Int((total.maxGpuSeconds * 1000.0).rounded()))")
        }
        self.lastReportTime = now
        self.reported = self.totals
        return "Sticker GPU time (since the last line): " + parts.joined(separator: "; ")
    }
}
