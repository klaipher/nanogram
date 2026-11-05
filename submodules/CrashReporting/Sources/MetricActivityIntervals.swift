import Foundation
import os
#if os(iOS)
import MetricKit
#endif

/// The app's activity intervals for MetricKit (`mxSignpost` through a MetricKit log handle). Usage: keep the token of
/// `begin(_:)` while the activity runs and let go of it (or call `end()`) when it stops.
public enum MetricActivityIntervals {
    public static func begin(_ activity: MetricActivity) -> ActivityIntervalCounter.Token {
        return MetricActivityIntervals.counter.begin(activity)
    }

    /// Begins the activity when `active` turns true and ends it when it turns false. Returns the token to keep.
    public static func update(_ token: ActivityIntervalCounter.Token?, _ activity: MetricActivity, active: Bool) -> ActivityIntervalCounter.Token? {
        if active {
            return token ?? MetricActivityIntervals.begin(activity)
        } else {
            token?.end()
            return nil
        }
    }

    private static let counter = ActivityIntervalCounter(onChange: { activity, isActive in
        MetricActivityIntervals.emit(activity, isActive: isActive)
    })

    #if os(iOS)
    private static let log: OSLog = {
        if #available(iOS 27.0, *) {
            return MetricManager.logHandle(category: "Nanogram.Activity")
        } else {
            return MXMetricManager.makeLogHandle(category: "Nanogram.Activity")
        }
    }()

    // Overlapping intervals of different activities need distinct ids; one interval per activity is open at a time.
    private static let ids: [MetricActivity: OSSignpostID] = {
        var result: [MetricActivity: OSSignpostID] = [:]
        for activity in MetricActivity.allCases {
            result[activity] = OSSignpostID(log: MetricActivityIntervals.log)
        }
        return result
    }()

    private static func emit(_ activity: MetricActivity, isActive: Bool) {
        let type: OSSignpostType = isActive ? .begin : .end
        let id = MetricActivityIntervals.ids[activity] ?? .exclusive
        let log = MetricActivityIntervals.log
        switch activity {
        case .stickerPlayback:
            mxSignpost(type, log: log, name: "stickerPlayback", signpostID: id)
        case .videoPlayback:
            mxSignpost(type, log: log, name: "videoPlayback", signpostID: id)
        case .call:
            mxSignpost(type, log: log, name: "call", signpostID: id)
        case .roundVideoRecording:
            mxSignpost(type, log: log, name: "roundVideoRecording", signpostID: id)
        }
    }
    #else
    private static func emit(_ activity: MetricActivity, isActive: Bool) {
    }
    #endif
}
