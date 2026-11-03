import Foundation
import UIKit
import QuartzCore
import SwiftSignalKit

// iPad energy decisions from the iPadOS 27 audit (2026-11-03), second batch: B-3 (Power Saving follows the system's
// signals) and B-1 (the shared display link's 120 Hz override, behind a Debug Settings switch). Pure functions, as in
// `TabletSystemRules.swift`, tested by `//submodules/Display:TabletSystemTests`. Phones reduce to upstream.

// MARK: - B-3 Power Saving follows the system

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
/// only, so a plugged-in iPad never entered it however hot it ran. Tablet only: on a phone, never.
public func systemRequestsEnergySaving(_ conditions: SystemEnergyConditions, deviceType: DeviceType) -> Bool {
    guard case .tablet = deviceType else {
        return false
    }
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
/// percentage (upstream), and also, on an iPad, while the system asks for it (`systemRequests`). It turns off again
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

/// Watches the system's energy conditions (`SystemEnergyConditions`) for automatic Power Saving. Its device type is
/// set once at launch from the main window; until then, and on phones, it never requests energy saving and observes
/// nothing.
public final class SystemEnergyConditionsMonitor {
    public static let shared = SystemEnergyConditionsMonitor(notificationCenter: .default, read: { SystemEnergyConditions.current() })

    /// How long the thermal state must stay below serious before Power Saving it caused turns off.
    public static let thermalReleaseDelay: Double = 120.0

    private let notificationCenter: NotificationCenter
    private let read: () -> SystemEnergyConditions
    private let now: () -> Double
    private let schedule: (Double, @escaping () -> Void) -> Disposable

    public var deviceType: DeviceType = .phone

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

    /// Whether this monitor ever observes the system: on a tablet only. Elsewhere callers keep upstream's
    /// battery-only Power Saving signal unchanged (review I5).
    public var observesSystemConditions: Bool {
        if case .tablet = self.deviceType {
            return true
        } else {
            return false
        }
    }

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
    /// thread), and when a thermal cool-down ends. A single false on phones.
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

// MARK: - B-1 Shared display link rate on iPad

/// The frame rate range the app's shared display link asks for. `requested` is the fastest of its active links
/// (emoji, stickers, GIF-like animations ask 60 or 30, scrolling-driven ones more). Upstream then forces 30–120 Hz,
/// preferred 120, on every iPad with a 120 Hz screen (`isTablet`), so one visible animated emoji wakes the main thread
/// 120 times a second there, four times the phone's rate. With `capsTabletRate` (Debug Settings, off by default, for
/// the owner's on-device A/B) an iPad follows the phone rule: 120 Hz only when a link asks for more than 60.
public func sharedDisplayLinkFrameRateRange(requested: SharedDisplayLinkDriver.FramesPerSecond, displayMaxFramesPerSecond: Float, isTablet: Bool, capsTabletRate: Bool) -> CAFrameRateRange {
    var frameRateRange: CAFrameRateRange = .default
    switch requested {
    case let .fps(fps):
        if fps > 60 {
            if displayMaxFramesPerSecond > 61.0 {
                frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
            }
        } else if fps <= 30 {
            // Every active link wants 30 fps or less (emoji, stickers in Low Power Mode...):
            // ask for 30 instead of waking at the full display rate only to skip frames.
            // Scrolling and Core Animation request their own, higher rates.
            frameRateRange = CAFrameRateRange(minimum: 15.0, maximum: 30.0, preferred: 30.0)
        } else if displayMaxFramesPerSecond > 61.0 {
            // On 120 Hz screens `.default` let the link run at 120 Hz (the app disables the
            // minimum frame duration), waking twice per 60 fps frame.
            frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 60.0, preferred: 60.0)
        }
    case .max:
        if displayMaxFramesPerSecond > 61.0 {
            frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
        }
    }
    if isTablet && !capsTabletRate && displayMaxFramesPerSecond > 61.0 {
        frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
    }
    return frameRateRange
}

/// Frame pacing of the shared display link over a window of time, for the B-1 A/B: how many callbacks it delivered,
/// their average rate, and how many came late (an interval more than 1.5 times the frame duration the link was
/// running at). One log line per window (`summary`), so a run with the cap on and one with it off can be compared.
public struct DisplayLinkPacingStats: Equatable {
    public private(set) var frames: Int = 0
    public private(set) var lateFrames: Int = 0
    public private(set) var elapsed: Double = 0.0
    public private(set) var longestInterval: Double = 0.0
    private var lastTimestamp: Double?

    public init() {
    }

    /// Records one callback at `timestamp` (the link's `timestamp`) running at `frameDuration` seconds per frame.
    public mutating func record(timestamp: Double, frameDuration: Double) {
        defer {
            self.lastTimestamp = timestamp
        }
        guard let lastTimestamp = self.lastTimestamp else {
            return
        }
        let interval = timestamp - lastTimestamp
        guard interval > 0.0 else {
            return
        }
        self.frames += 1
        self.elapsed += interval
        self.longestInterval = max(self.longestInterval, interval)
        if frameDuration > 0.0 && interval > frameDuration * 1.5 {
            self.lateFrames += 1
        }
    }

    /// Forgets the previous timestamp: the link paused, so the next interval is not a frame.
    public mutating func pause() {
        self.lastTimestamp = nil
    }

    /// A log line once `windowDuration` seconds of frames were recorded, nil before.
    public func summary(windowDuration: Double, capsTabletRate: Bool, preferredFramesPerSecond: Float) -> String? {
        guard self.elapsed >= windowDuration, self.frames > 0 else {
            return nil
        }
        let averageHz = Double(self.frames) / self.elapsed
        let latePercent = Double(self.lateFrames) * 100.0 / Double(self.frames)
        return String(format: "cap=%@ preferred=%.0f frames=%d seconds=%.1f avgHz=%.1f late=%d (%.1f%%) longestMs=%.1f", capsTabletRate ? "on" : "off", preferredFramesPerSecond, self.frames, self.elapsed, averageHz, self.lateFrames, latePercent, self.longestInterval * 1000.0)
    }
}
