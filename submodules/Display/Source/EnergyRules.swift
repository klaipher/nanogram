import Foundation
import UIKit
import QuartzCore
import SwiftSignalKit

// Automatic Power Saving follows the system's energy signals on every device (first iPad-only as audit B-3 of the
// iPadOS 27 audit, 2026-11-03; on iPhone too since the owner asked). Pure rules plus the monitor that feeds them,
// tested by `//submodules/Display:EnergyRulesTests` (iPhone) and `:TabletSecondBatchTests` (the original B-3 cases).

/// The system's own requests to use less energy, read together.
public struct SystemEnergyConditions: Equatable {
    public var thermalState: ProcessInfo.ThermalState
    public var isLowPowerModeEnabled: Bool
    /// iOS 27 `UIApplication.systemPrefersReducedResourceUsage`; false before iOS 27.
    public var prefersReducedResourceUsage: Bool

    public init(thermalState: ProcessInfo.ThermalState, isLowPowerModeEnabled: Bool, prefersReducedResourceUsage: Bool) {
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.prefersReducedResourceUsage = prefersReducedResourceUsage
    }

    public static let nominal = SystemEnergyConditions(thermalState: .nominal, isLowPowerModeEnabled: false, prefersReducedResourceUsage: false)

    /// The last reduced-resource-usage value read on the main thread: `UIApplication` is read there only, and the
    /// thermal and power notifications arrive on any thread.
    private static let lastPrefersReducedResourceUsage = Atomic<Bool>(value: false)

    /// The device's current conditions.
    public static func current() -> SystemEnergyConditions {
        var prefersReducedResourceUsage = false
        if #available(iOS 27.0, *) {
            if Thread.isMainThread {
                prefersReducedResourceUsage = UIApplication.shared.systemPrefersReducedResourceUsage
                let _ = SystemEnergyConditions.lastPrefersReducedResourceUsage.swap(prefersReducedResourceUsage)
            } else {
                prefersReducedResourceUsage = SystemEnergyConditions.lastPrefersReducedResourceUsage.with { $0 }
            }
        }
        return SystemEnergyConditions(
            thermalState: ProcessInfo.processInfo.thermalState,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            prefersReducedResourceUsage: prefersReducedResourceUsage
        )
    }
}

/// Whether the system asks the app to save energy: a serious or critical thermal state, Low Power Mode, or the iOS 27
/// "reduced resource usage" preference (owner decision: all three). Upstream's Power Saving follows the battery level
/// only, so a plugged-in device never entered it however hot it ran. The same on every device type.
public func systemRequestsEnergySaving(_ conditions: SystemEnergyConditions) -> Bool {
    switch conditions.thermalState {
    case .serious, .critical:
        return true
    default:
        break
    }
    return conditions.isLowPowerModeEnabled || conditions.prefersReducedResourceUsage
}

/// Whether automatic Power Saving is on. `activationThreshold` is the user's slider (Settings ▸ Power Saving): 4 or
/// less is "Off", which nothing overrides, 96 or more is "Always"; in between it turns on at or below that battery
/// percentage (upstream), and also while the system asks for it (`systemRequests`). It turns off again
/// when neither holds, which restores the user's own per-feature switches.
public func automaticEnergySavingIsOn(activationThreshold: Int32, batteryLevel: Float, systemRequests: Bool) -> Bool {
    if activationThreshold <= 4 {
        return false
    }
    if systemRequests {
        return true
    }
    return automaticEnergySavingBatteryConditionIsOn(activationThreshold: activationThreshold, batteryLevel: batteryLevel)
}

/// Upstream's battery rule alone: what the "Power Saving is on at N% battery" alert describes.
public func automaticEnergySavingBatteryConditionIsOn(activationThreshold: Int32, batteryLevel: Float) -> Bool {
    if activationThreshold <= 4 {
        return false
    } else if activationThreshold >= 96 {
        return true
    } else if batteryLevel < 0.0 {
        return false
    } else {
        return batteryLevel <= Float(activationThreshold) / 100.0
    }
}

/// The thermal half of `systemRequestsEnergySaving`, with hysteresis (review I4): on as soon as the state is serious or
/// critical, off only once it has stayed at fair or below for `releaseDelay`, counted from the last serious reading.
/// Under load the state often moves between fair and serious, and without this each move switched the whole energy
/// settings (autoplay, animations) on and off.
public struct ThermalEnergySavingLatch: Equatable {
    public private(set) var isOn: Bool = false
    /// When the state was first read below serious since it was last serious, while on.
    public private(set) var coolSince: Double?

    public init() {
    }

    public mutating func update(thermalState: ProcessInfo.ThermalState, now: Double, releaseDelay: Double) {
        switch thermalState {
        case .serious, .critical:
            self.isOn = true
            self.coolSince = nil
        default:
            guard self.isOn else {
                self.coolSince = nil
                return
            }
            let coolSince = self.coolSince ?? now
            if now - coolSince >= releaseDelay {
                self.isOn = false
                self.coolSince = nil
            } else {
                self.coolSince = coolSince
            }
        }
    }

    /// When it turns off if the state stays below serious; nil when off or still hot.
    public func releaseTime(releaseDelay: Double) -> Double? {
        guard self.isOn, let coolSince = self.coolSince else {
            return nil
        }
        return coolSince + releaseDelay
    }
}

/// Watches the system's energy conditions (`SystemEnergyConditions`) for automatic Power Saving, on every device type.
/// The app turns it on once at launch (`observesSystemConditions`); until then, and in app extensions, it never
/// requests energy saving and observes nothing.
public final class SystemEnergyConditionsMonitor {
    public static let shared = SystemEnergyConditionsMonitor(notificationCenter: .default, read: { SystemEnergyConditions.current() })

    /// How long the thermal state must stay below serious before Power Saving it caused turns off.
    public static let thermalReleaseDelay: Double = 120.0

    private let notificationCenter: NotificationCenter
    private let read: () -> SystemEnergyConditions
    private let now: () -> Double
    private let schedule: (Double, @escaping () -> Void) -> Disposable

    /// Whether this monitor observes the system at all: set by the main app at launch. Off, callers keep upstream's
    /// battery-only Power Saving signal unchanged (review I5), as app extensions do.
    public var observesSystemConditions: Bool = false

    public init(notificationCenter: NotificationCenter, read: @escaping () -> SystemEnergyConditions, now: @escaping () -> Double = { CACurrentMediaTime() }, schedule: @escaping (Double, @escaping () -> Void) -> Disposable = SystemEnergyConditionsMonitor.mainQueueTimer) {
        self.notificationCenter = notificationCenter
        self.read = read
        self.now = now
        self.schedule = schedule
    }

    public static func mainQueueTimer(delay: Double, action: @escaping () -> Void) -> Disposable {
        let timer = SwiftSignalKit.Timer(timeout: delay, repeat: false, completion: action, queue: Queue.mainQueue())
        timer.start()
        return ActionDisposable {
            timer.invalidate()
        }
    }

    private let thermalLatch = Atomic<ThermalEnergySavingLatch>(value: ThermalEnergySavingLatch())

    /// Whether the system asks to save energy right now: Low Power Mode or reduced resource usage as they are, the
    /// thermal state through `ThermalEnergySavingLatch`.
    public var requestsEnergySaving: Bool {
        guard self.observesSystemConditions else {
            return false
        }
        return self.evaluate().requests
    }

    private func evaluate() -> (requests: Bool, releaseIn: Double?) {
        let conditions = self.read()
        let now = self.now()
        let releaseDelay = SystemEnergyConditionsMonitor.thermalReleaseDelay
        let latch = self.thermalLatch.modify { latch in
            var latch = latch
            latch.update(thermalState: conditions.thermalState, now: now, releaseDelay: releaseDelay)
            return latch
        }
        let requests = latch.isOn || conditions.isLowPowerModeEnabled || conditions.prefersReducedResourceUsage
        return (requests, latch.releaseTime(releaseDelay: releaseDelay).map { max(0.0, $0 - now) })
    }

    /// Sends the current value, and while a thermal release is pending, reads again when it is due (no notification
    /// marks the end of the cool-down).
    private func deliver(to subscriber: Subscriber<Bool, NoError>, recheck: MetaDisposable) {
        let (requests, releaseIn) = self.evaluate()
        subscriber.putNext(requests)
        if let releaseIn {
            recheck.set(self.schedule(releaseIn, { [weak self] in
                self?.deliver(to: subscriber, recheck: recheck)
            }))
        } else {
            recheck.set(nil)
        }
    }

    /// The names of the notifications after which the conditions are read again.
    public static var conditionChangeNotifications: [Notification.Name] {
        var names: [Notification.Name] = [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
        if #available(iOS 27.0, *) {
            names.append(UIApplication.systemPrefersReducedResourceUsageDidChangeNotification)
        }
        return names
    }

    /// `requestsEnergySaving` now, again whenever a condition may have changed (the notifications can arrive on any
    /// thread), and when a thermal cool-down ends. A single false while it does not observe the system.
    public func requestsEnergySavingUpdates() -> Signal<Bool, NoError> {
        guard self.observesSystemConditions else {
            return .single(false)
        }
        let notificationCenter = self.notificationCenter
        return Signal { [weak self] subscriber in
            let recheck = MetaDisposable()
            if let self {
                self.deliver(to: subscriber, recheck: recheck)
            } else {
                subscriber.putNext(false)
            }
            let observers = SystemEnergyConditionsMonitor.conditionChangeNotifications.map { name in
                return notificationCenter.addObserver(forName: name, object: nil, queue: nil, using: { _ in
                    if let self {
                        self.deliver(to: subscriber, recheck: recheck)
                    } else {
                        subscriber.putNext(false)
                    }
                })
            }
            return ActionDisposable {
                for observer in observers {
                    notificationCenter.removeObserver(observer)
                }
                recheck.dispose()
            }
        }
    }
}
