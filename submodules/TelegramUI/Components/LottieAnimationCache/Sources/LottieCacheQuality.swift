import Foundation
import UIKit

/// How a Lottie animation is cached for a surface that wants it as smooth and sharp as the source allows,
/// such as the large reaction in a reaction's context menu.
///
/// The standard cache keeps every second frame (a 60 fps animation plays at 30 fps) and is rendered at no more
/// than 2x, whatever the screen: that is what the emoji and sticker grids want, many small items at a low cost.
/// A `full` cache keeps every frame and is rendered at the screen's scale. It is a separate cache entry, so
/// asking for it never changes what the standard surfaces show.
///
/// Power: `full` is only given while the system does not ask for less. In Low Power Mode, under a serious or
/// critical thermal state and on a device with two cores or fewer, a surface that asked for it gets the standard
/// cache, which is what it showed before.
public enum LottieCacheQuality: Equatable {
    case standard
    case full

    /// The quality a surface gets when it asks for `.full` under the given system conditions.
    public static func effective(requestsFull: Bool, isLowPowerMode: Bool, thermalState: ProcessInfo.ThermalState, processorCount: Int) -> LottieCacheQuality {
        guard requestsFull else {
            return .standard
        }
        if isLowPowerMode || processorCount <= 2 {
            return .standard
        }
        switch thermalState {
        case .serious, .critical:
            return .standard
        case .nominal, .fair:
            return .full
        @unknown default:
            return .standard
        }
    }

    /// The quality for the current state of the device.
    public static func current(requestsFull: Bool) -> LottieCacheQuality {
        let processInfo = ProcessInfo.processInfo
        return LottieCacheQuality.effective(requestsFull: requestsFull, isLowPowerMode: processInfo.isLowPowerModeEnabled, thermalState: processInfo.thermalState, processorCount: processInfo.processorCount)
    }

    /// Source frames skipped between two cached frames: 1 keeps every frame.
    public var frameSkip: Int {
        switch self {
        case .standard:
            return 2
        case .full:
            return 1
        }
    }

    /// Pixels per point of the cached frames on a screen of the given scale.
    public func pixelScale(screenScale: CGFloat) -> CGFloat {
        switch self {
        case .standard:
            return min(2.0, screenScale)
        case .full:
            return screenScale
        }
    }

    /// The id the animation is cached under. A `full` entry has its own, so it never meets a standard one of
    /// the same size (on a 2x screen both are the same size).
    public func cacheSourceId(_ sourceId: String) -> String {
        switch self {
        case .standard:
            return sourceId
        case .full:
            return sourceId + "#full"
        }
    }
}
