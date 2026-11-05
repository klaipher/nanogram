import Foundation
import UIKit
import Display

// How often the emoji and sticker renderer ticks, and what drives the tick.
enum DCTAnimationTickPolicy {
    // 1 ticks at 60 Hz, 2 at 30 Hz. Half rate on Low Power Mode, on a serious or critical thermal state
    // (Apple: reduce animation work as the device heats up) and on devices with two cores or fewer.
    static func frameSkip(isLowPowerMode: Bool, thermalState: ProcessInfo.ThermalState, processorCount: Int) -> Int {
        if isLowPowerMode || processorCount <= 2 {
            return 2
        }
        switch thermalState {
        case .serious, .critical:
            return 2
        case .nominal, .fair:
            return 1
        @unknown default:
            return 1
        }
    }

    // The display-link rate for a tick interval, 1 to 60. An unusable interval counts as 60.
    static func framesPerSecond(forTickInterval interval: Double) -> Int {
        guard interval > 0.0 else {
            return 60
        }
        let fps = (1.0 / interval).rounded()
        if fps >= 60.0 {
            return 60
        }
        if fps <= 1.0 {
            return 1
        }
        return Int(fps)
    }
}

extension DCTAnimationTickPolicy {
    // The time a tick advances the animations. A link at a fixed rate can fire later than its nominal interval
    // (Low Power Mode and thermal pressure lower the display rate, a 40 Hz tick on a 60 Hz display fires every
    // 25 ms but the link would report 1/40 s), so the elapsed time is the distance between the target timestamps of
    // two callbacks (Apple, WWDC21 10147: progress += targetTimestamp - previousTargetTimestamp). Never below one
    // interval, and at most four after a stall (the app was suspended or busy), so a long gap does not skip
    // a whole animation.
    static func elapsed(target: Double, previousTarget: Double?, interval: Double) -> Double {
        guard let previousTarget, target.isFinite, previousTarget.isFinite else {
            return interval
        }
        return min(max(target - previousTarget, interval), 4.0 * interval)
    }
}

extension DCTAnimationTickScheduler {
    // Ticks from the app's shared display link instead of a run loop timer: the system matches the display's
    // refresh rate to the tick rate (a 30 Hz tick lets a 120 Hz screen idle at lower cost), and the link stops
    // while the app is in the background. Ticks come on the main thread, like the timer's.
    static let sharedDisplayLink = DCTAnimationTickScheduler(start: { interval, tick in
        let fps = DCTAnimationTickPolicy.framesPerSecond(forTickInterval: interval)
        // The callback argument is a fixed 1/fps for .fps links, so the elapsed time comes from the driver's
        // last target timestamp.
        var previousTarget: Double?
        let link = SharedDisplayLinkDriver.shared.add(framesPerSecond: .fps(fps), { _ in
            let target = SharedDisplayLinkDriver.shared.lastTargetTimestamp
            let elapsed = target.map { DCTAnimationTickPolicy.elapsed(target: $0, previousTarget: previousTarget, interval: interval) } ?? interval
            previousTarget = target ?? previousTarget
            tick(elapsed)
        })
        link.isPaused = false
        return {
            link.isPaused = true
            link.invalidate()
        }
    })
}
