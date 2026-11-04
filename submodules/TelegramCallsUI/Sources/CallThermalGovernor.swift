import Foundation
import UIKit
import SwiftSignalKit

/// How hot the device is, from a call's point of view. Level 1 only marks Low Power Mode; the video ladder acts
/// from level 2 up.
public enum CallThermalLevel: Int, Comparable {
    case nominal = 0
    case elevated = 1
    case high = 2
    case critical = 3

    public static func <(lhs: CallThermalLevel, rhs: CallThermalLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    /// Whether the outgoing video should be handed to the encoder smaller and slower.
    public var shrinksVideo: Bool {
        return self >= .high
    }
}

public enum CallThermalMapping {
    /// `fair` is normal operation for a call, so it stays nominal; Low Power Mode alone is a soft signal.
    public static func level(thermalState: ProcessInfo.ThermalState, isLowPowerModeEnabled: Bool) -> CallThermalLevel {
        var result: CallThermalLevel
        switch thermalState {
        case .nominal, .fair:
            result = .nominal
        case .serious:
            result = .high
        case .critical:
            result = .critical
        @unknown default:
            result = .nominal
        }
        if isLowPowerModeEnabled {
            result = max(result, .elevated)
        }
        return result
    }
}

/// Raises the level at once and lowers it only after the cooler reading has held for a release delay: 5 s for
/// changes that only affect the UI, 30 s when the outgoing video grows back (every resolution change reconfigures
/// the encoder and forces a keyframe, so a phone that moves between fair and serious every few seconds must not
/// make the camera size flip each time). Same as the Mac's CallPowerHysteresis.
public struct CallThermalHysteresis {
    public static let releaseDelay: Double = 5.0
    public static let videoReleaseDelay: Double = 30.0

    public private(set) var current: CallThermalLevel = .nominal
    private var lowerSince: Double?
    private var lowerTarget: CallThermalLevel?

    public init() {
    }

    /// How long a cooler reading `target` must hold before it replaces `current`.
    public static func delay(from current: CallThermalLevel, to target: CallThermalLevel) -> Double {
        return current.shrinksVideo && !target.shrinksVideo ? self.videoReleaseDelay : self.releaseDelay
    }

    /// The time at which a pending lowering takes effect, if one is pending.
    public var releaseTime: Double? {
        guard let lowerSince = self.lowerSince, let lowerTarget = self.lowerTarget else {
            return nil
        }
        return lowerSince + CallThermalHysteresis.delay(from: self.current, to: lowerTarget)
    }

    public mutating func update(raw: CallThermalLevel, now: Double) -> CallThermalLevel {
        if raw >= self.current {
            self.lowerSince = nil
            self.lowerTarget = nil
            self.current = raw
        } else {
            if self.lowerSince == nil {
                self.lowerSince = now
            }
            self.lowerTarget = raw
            if let lowerSince = self.lowerSince, now - lowerSince >= CallThermalHysteresis.delay(from: self.current, to: raw) {
                self.current = raw
                self.lowerSince = nil
                self.lowerTarget = nil
            }
        }
        return self.current
    }
}

/// Watches the system thermal state and Low Power Mode and publishes the call thermal level. Main thread.
public final class CallThermalGovernor {
    public static let shared = CallThermalGovernor()

    private var hysteresis = CallThermalHysteresis()
    private let promise = ValuePromise<CallThermalLevel>(.nominal, ignoreRepeated: true)
    private var observers: [NSObjectProtocol] = []
    private var recheckTimer: Foundation.Timer?
    private var isObserving = false

    public var level: Signal<CallThermalLevel, NoError> {
        return self.promise.get()
    }

    private init() {
    }

    /// Starts observing. Called when the first call starts; harmless to call again.
    public func start() {
        if self.isObserving {
            return
        }
        self.isObserving = true
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] _ in
            self?.evaluate()
        }
        self.observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: handler))
        self.observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: handler))
        self.evaluate()
    }

    private func evaluate() {
        let info = ProcessInfo.processInfo
        let raw = CallThermalMapping.level(thermalState: info.thermalState, isLowPowerModeEnabled: info.isLowPowerModeEnabled)
        let now = CACurrentMediaTime()
        let level = self.hysteresis.update(raw: raw, now: now)
        self.promise.set(level)

        self.recheckTimer?.invalidate()
        self.recheckTimer = nil
        if let releaseTime = self.hysteresis.releaseTime {
            let delay = max(0.1, releaseTime - now)
            self.recheckTimer = Foundation.Timer.scheduledTimer(withTimeInterval: delay, repeats: false, block: { [weak self] _ in
                self?.evaluate()
            })
        }
    }
}
