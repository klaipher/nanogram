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
