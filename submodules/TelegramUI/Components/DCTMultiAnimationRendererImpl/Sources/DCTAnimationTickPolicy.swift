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

extension DCTAnimationTickScheduler {
    // Ticks from the app's shared display link instead of a run loop timer: the system matches the display's
    // refresh rate to the tick rate (a 30 Hz tick lets a 120 Hz screen idle at lower cost), and the link stops
    // while the app is in the background. Ticks come on the main thread, like the timer's.
    static let sharedDisplayLink = DCTAnimationTickScheduler(start: { interval, tick in
        let fps = DCTAnimationTickPolicy.framesPerSecond(forTickInterval: interval)
        let link = SharedDisplayLinkDriver.shared.add(framesPerSecond: .fps(fps), { _ in
            tick()
        })
        link.isPaused = false
        return {
            link.isPaused = true
            link.invalidate()
        }
    })
}
