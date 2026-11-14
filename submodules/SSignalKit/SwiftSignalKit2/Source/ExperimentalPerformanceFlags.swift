import Foundation

/// Device-dependent performance changes that ship dark. Each one is off unless its UserDefaults bool
/// (`nanogram.experiment.<name>`) is set, so a build can be A/B-measured on a device before the default changes.
public enum PerformanceExperiment: String, CaseIterable, Sendable {
    /// iOS ThreadPools use `Thread.qualityOfService` instead of the legacy `threadPriority` (iOS-QOS-1).
    case threadPoolQualityOfService
    /// Multi-threaded software AV1 decode on iOS, capped by core count, Low Power Mode and thermal state (IOS-SIMD-1).
    case softwareDecodeThreads
    /// VideoToolbox decode for gallery scrub previews (IOS-VIDEO-1).
    case previewHardwareDecode

    public var defaultsKey: String {
        return "nanogram.experiment.\(self.rawValue)"
    }
}

public final class ExperimentalPerformanceFlags: @unchecked Sendable {
    public static let shared = ExperimentalPerformanceFlags(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var overrides: [PerformanceExperiment: Bool] = [:]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func isEnabled(_ experiment: PerformanceExperiment) -> Bool {
        self.lock.lock()
        let override = self.overrides[experiment]
        self.lock.unlock()
        if let override {
            return override
        }
        return self.defaults.bool(forKey: experiment.defaultsKey)
    }

    /// Debug Settings and tests call this; nil returns to the stored value.
    public func setOverride(_ experiment: PerformanceExperiment, _ value: Bool?) {
        self.lock.lock()
        self.overrides[experiment] = value
        self.lock.unlock()
    }
}

public extension PerformanceExperiment {
    /// What a tester sees on the Debug Settings row.
    var title: String {
        switch self {
        case .threadPoolQualityOfService:
            return "Thread pools on quality of service"
        case .softwareDecodeThreads:
            return "AV1 video: several decode threads"
        case .previewHardwareDecode:
            return "Gallery scrubbing: hardware decode"
        }
    }

    var metric: PerformanceMetric {
        switch self {
        case .threadPoolQualityOfService:
            return .threadPoolQueueWait
        case .softwareDecodeThreads:
            return .av1FrameDecode
        case .previewHardwareDecode:
            return .scrubPreviewFrame
        }
    }
}

public enum PerformanceMetric: String, CaseIterable, Sendable {
    /// Time a thread-pool task waited between being created and starting to run.
    case threadPoolQueueWait
    /// Time spent decoding one software AV1 frame (the wait for the decoder's result).
    case av1FrameDecode
    /// Time from asking for a gallery scrub preview frame to having its image.
    case scrubPreviewFrame
}

/// Counts and times for the three experiments, summarised in the Debug Settings diagnostics. Only durations
/// are kept: no message content, file names or ids.
public final class PerformanceExperimentStats: @unchecked Sendable {
    public static let shared = PerformanceExperimentStats()

    public struct Summary: Equatable, Sendable {
        public var count: Int = 0
        public var totalSeconds: Double = 0.0
        public var maxSeconds: Double = 0.0

        public var averageSeconds: Double {
            return self.count == 0 ? 0.0 : self.totalSeconds / Double(self.count)
        }
    }

    private let lock = NSLock()
    private var summaries: [PerformanceMetric: Summary] = [:]

    public init() {
    }

    public func record(_ metric: PerformanceMetric, seconds: Double) {
        guard seconds >= 0.0, seconds.isFinite else {
            return
        }
        self.lock.lock()
        var summary = self.summaries[metric] ?? Summary()
        summary.count += 1
        summary.totalSeconds += seconds
        summary.maxSeconds = max(summary.maxSeconds, seconds)
        self.summaries[metric] = summary
        self.lock.unlock()
    }

    public func summary(_ metric: PerformanceMetric) -> Summary {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.summaries[metric] ?? Summary()
    }

    public func reset() {
        self.lock.lock()
        self.summaries = [:]
        self.lock.unlock()
    }

    /// One line per experiment: its state and the numbers measured since launch (or the last reset).
    public func summaryLines(flags: ExperimentalPerformanceFlags = .shared) -> [String] {
        return PerformanceExperiment.allCases.map { experiment in
            let state = flags.isEnabled(experiment) ? "on" : "off"
            let summary = self.summary(experiment.metric)
            let numbers: String
            if summary.count == 0 {
                numbers = "no samples"
            } else {
                numbers = "n=\(summary.count) avg=\(PerformanceExperimentStats.milliseconds(summary.averageSeconds)) ms max=\(PerformanceExperimentStats.milliseconds(summary.maxSeconds)) ms"
            }
            return "\(experiment.rawValue)=\(state) \(experiment.metric.rawValue): \(numbers)"
        }
    }

    static func milliseconds(_ seconds: Double) -> String {
        let value = (seconds * 10000.0).rounded() / 10.0
        return String(value)
    }
}

public func performanceExperimentsReport(modelIdentifier: String, flags: ExperimentalPerformanceFlags = .shared, stats: PerformanceExperimentStats = .shared) -> String {
    var lines = ["Performance experiments (device \(modelIdentifier))"]
    lines.append(contentsOf: stats.summaryLines(flags: flags))
    return lines.joined(separator: "\n")
}
