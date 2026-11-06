import Foundation

/// The two chat-scroll switches in Debug Settings (main app only, both off by default). The raw values are the bits
/// of `ExperimentalUISettings.chatScrollExperiments`.
public enum ChatScrollExperiment: Int32, CaseIterable {
    /// "Chat rows: prepare layout ahead": the text layout and sizes of rows about to enter the load band are
    /// computed on a background queue and used when the list asks for the row, if the key matches exactly.
    case prepareLayoutAhead = 1
    /// "Chat rows: reuse row views": rows leaving the load band are torn down at an idle run-loop turn, and
    /// certified view types are reset and reused instead of destroyed.
    case reuseRowViews = 2
}

/// The cached state of the switches. Written on the main thread when the settings change; the scroll path reads
/// two stored Bools, so with both off a guard costs one load and one branch.
public enum ChatScrollExperiments {
    public private(set) static var mask: Int32 = 0
    public private(set) static var isPrepareLayoutAheadEnabled: Bool = false
    public private(set) static var isReuseRowViewsEnabled: Bool = false

    public static func mask(of experiments: [ChatScrollExperiment]) -> Int32 {
        return experiments.reduce(0) { $0 | $1.rawValue }
    }

    /// `mask` with `experiment` turned on or off.
    public static func mask(_ mask: Int32, setting experiment: ChatScrollExperiment, enabled: Bool) -> Int32 {
        return enabled ? (mask | experiment.rawValue) : (mask & ~experiment.rawValue)
    }

    /// Unknown bits are dropped.
    public static func setMask(_ mask: Int32) {
        let known = self.mask(of: ChatScrollExperiment.allCases)
        let mask = mask & known
        self.mask = mask
        self.isPrepareLayoutAheadEnabled = mask & ChatScrollExperiment.prepareLayoutAhead.rawValue != 0
        self.isReuseRowViewsEnabled = mask & ChatScrollExperiment.reuseRowViews.rawValue != 0
    }
}
