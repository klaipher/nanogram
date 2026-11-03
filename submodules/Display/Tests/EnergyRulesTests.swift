import XCTest
import UIKit
import SwiftSignalKit
@testable import Display

/// Automatic Power Saving follows the system's energy signals on an iPhone too (first shipped for iPad, audit B-3):
/// a serious or critical thermal state, Low Power Mode, and iOS 27's reduced-resource-usage request. The rules are
/// the iPad's: the user's "Off" is never overridden, it turns off again when the signal clears (restoring the user's
/// own switches), the thermal signal has hysteresis, and the battery alert describes only the battery.
final class EnergyRulesTests: XCTestCase {
    private func conditions(thermal: ProcessInfo.ThermalState = .nominal, lowPower: Bool = false, reduced: Bool = false) -> SystemEnergyConditions {
        return SystemEnergyConditions(thermalState: thermal, isLowPowerModeEnabled: lowPower, prefersReducedResourceUsage: reduced)
    }

    /// A clock and a one-shot timer the test moves by hand.
    private final class Clock {
        var time: Double = 0.0
        private var pending: [(due: Double, action: () -> Void, cancelled: Bool)] = []

        func schedule(_ delay: Double, _ action: @escaping () -> Void) -> Disposable {
            let index = self.pending.count
            self.pending.append((self.time + delay, action, false))
            return ActionDisposable { [weak self] in
                self?.pending[index].cancelled = true
            }
        }

        func advance(to time: Double) {
            self.time = time
            var index = 0
            while index < self.pending.count {
                if !self.pending[index].cancelled && self.pending[index].due <= time {
                    self.pending[index].cancelled = true
                    self.pending[index].action()
                }
                index += 1
            }
        }
    }

    /// The monitor as the app sets it up on an iPhone: it has no device type, only whether the app turned it on
    /// (the main app does on every device, `SharedAccountContextImpl`).
    private func phoneMonitor(center: NotificationCenter, clock: Clock, read: @escaping () -> SystemEnergyConditions) -> SystemEnergyConditionsMonitor {
        let monitor = SystemEnergyConditionsMonitor(notificationCenter: center, read: read, now: { clock.time }, schedule: clock.schedule)
        monitor.observesSystemConditions = true
        return monitor
    }

    // MARK: - The pure rule

    func test_phone_eachSystemSignalRequestsEnergySaving() {
        XCTAssertFalse(systemRequestsEnergySaving(self.conditions()))
        XCTAssertFalse(systemRequestsEnergySaving(self.conditions(thermal: .fair)))
        XCTAssertTrue(systemRequestsEnergySaving(self.conditions(thermal: .serious)))
        XCTAssertTrue(systemRequestsEnergySaving(self.conditions(thermal: .critical)))
        XCTAssertTrue(systemRequestsEnergySaving(self.conditions(lowPower: true)))
        XCTAssertTrue(systemRequestsEnergySaving(self.conditions(reduced: true)))
    }

    /// The phone used to ignore every signal (`TabletSecondBatchRulesTests.test_phone_systemSignalsAreIgnored`, removed).
    func test_sameRuleWithoutDeviceType() {
        for thermal: ProcessInfo.ThermalState in [.nominal, .fair, .serious, .critical] {
            for lowPower in [false, true] {
                for reduced in [false, true] {
                    let expected = thermal == .serious || thermal == .critical || lowPower || reduced
                    XCTAssertEqual(systemRequestsEnergySaving(self.conditions(thermal: thermal, lowPower: lowPower, reduced: reduced)), expected)
                }
            }
        }
    }

    // MARK: - The monitor on an iPhone

    /// Until the app turns it on (and in app extensions, where it never does) it observes nothing: callers keep
    /// upstream's battery signal.
    func test_monitor_offUntilTheAppTurnsItOn() {
        let center = NotificationCenter()
        let monitor = SystemEnergyConditionsMonitor(notificationCenter: center, read: { SystemEnergyConditions(thermalState: .critical, isLowPowerModeEnabled: true, prefersReducedResourceUsage: true) })
        XCTAssertFalse(monitor.observesSystemConditions)
        XCTAssertFalse(monitor.requestsEnergySaving)
        var values: [Bool] = []
        let disposable = monitor.requestsEnergySavingUpdates().start(next: { values.append($0) })
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(values, [false])
        disposable.dispose()

        monitor.observesSystemConditions = true
        XCTAssertTrue(monitor.requestsEnergySaving)
    }

    /// Each signal turns it on, through its own notification, and it turns off when the signal clears.
    func test_phone_monitor_followsEachSignalAndClears() {
        let center = NotificationCenter()
        let clock = Clock()
        var current = self.conditions()
        let monitor = self.phoneMonitor(center: center, clock: clock, read: { current })

        var values: [Bool] = []
        let disposable = monitor.requestsEnergySavingUpdates().start(next: { values.append($0) })
        XCTAssertEqual(values, [false])

        current = self.conditions(lowPower: true)
        center.post(name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertEqual(values.last, true)
        current = self.conditions()
        center.post(name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertEqual(values.last, false, "Low Power Mode clears at once")

        if #available(iOS 27.0, *) {
            current = self.conditions(reduced: true)
            center.post(name: UIApplication.systemPrefersReducedResourceUsageDidChangeNotification, object: nil)
            XCTAssertEqual(values.last, true)
            current = self.conditions()
            center.post(name: UIApplication.systemPrefersReducedResourceUsageDidChangeNotification, object: nil)
            XCTAssertEqual(values.last, false, "reduced resource usage clears at once")
        }

        current = self.conditions(thermal: .serious)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(values.last, true)
        XCTAssertTrue(monitor.requestsEnergySaving)
        disposable.dispose()
    }

    /// The iPad's hysteresis: on at serious, off only after the state stayed at fair or below for the release delay.
    func test_phone_monitor_thermalHysteresis() {
        let center = NotificationCenter()
        let clock = Clock()
        var current = self.conditions()
        let monitor = self.phoneMonitor(center: center, clock: clock, read: { current })

        var values: [Bool] = []
        let disposable = monitor.requestsEnergySavingUpdates().start(next: { values.append($0) })
        func post(at time: Double, _ conditions: SystemEnergyConditions) {
            clock.advance(to: time)
            current = conditions
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        }

        post(at: 0.0, self.conditions(thermal: .critical))
        XCTAssertEqual(values.last, true)
        post(at: 10.0, self.conditions(thermal: .fair))
        post(at: 20.0, self.conditions(thermal: .serious))
        post(at: 30.0, self.conditions(thermal: .nominal))
        clock.advance(to: 30.0 + SystemEnergyConditionsMonitor.thermalReleaseDelay - 1.0)
        XCTAssertEqual(values.last, true, "still cooling down")
        clock.advance(to: 30.0 + SystemEnergyConditionsMonitor.thermalReleaseDelay)
        XCTAssertEqual(values.last, false, "released without another notification")

        var transitions: [Bool] = []
        for value in values where transitions.last != value {
            transitions.append(value)
        }
        XCTAssertEqual(transitions, [false, true, false])
        disposable.dispose()
    }

    // MARK: - Power Saving on an iPhone

    /// Automatic mode (slider between Off and Always) with a full battery: on while the system asks, off again (the
    /// user's own switches restored) when it stops asking.
    func test_phone_automaticPowerSaving_onWhileRequested_restoredWhenCleared() {
        let clock = Clock()
        var current = self.conditions(lowPower: true)
        let monitor = self.phoneMonitor(center: NotificationCenter(), clock: clock, read: { current })

        XCTAssertTrue(automaticEnergySavingIsOn(activationThreshold: 15, batteryLevel: 1.0, systemRequests: monitor.requestsEnergySaving))
        current = self.conditions()
        XCTAssertFalse(automaticEnergySavingIsOn(activationThreshold: 15, batteryLevel: 1.0, systemRequests: monitor.requestsEnergySaving))
    }

    /// "Off" is the user's choice: a hot iPhone in Low Power Mode asking for reduced resource usage stays off.
    func test_phone_userOff_isNeverOverridden() {
        let clock = Clock()
        let monitor = self.phoneMonitor(center: NotificationCenter(), clock: clock, read: { SystemEnergyConditions(thermalState: .critical, isLowPowerModeEnabled: true, prefersReducedResourceUsage: true) })
        XCTAssertTrue(monitor.requestsEnergySaving)
        for threshold: Int32 in [0, 4] {
            XCTAssertFalse(automaticEnergySavingIsOn(activationThreshold: threshold, batteryLevel: 0.01, systemRequests: monitor.requestsEnergySaving))
        }
    }

    /// The "Power Saving is on at N% battery" alert: when the system turned it on, the battery rule says no.
    func test_phone_batteryAlertOnlyWhenBatteryIsTheCause() {
        let clock = Clock()
        let monitor = self.phoneMonitor(center: NotificationCenter(), clock: clock, read: { SystemEnergyConditions(thermalState: .serious, isLowPowerModeEnabled: false, prefersReducedResourceUsage: false) })
        XCTAssertTrue(automaticEnergySavingIsOn(activationThreshold: 15, batteryLevel: 0.8, systemRequests: monitor.requestsEnergySaving))
        XCTAssertFalse(automaticEnergySavingBatteryConditionIsOn(activationThreshold: 15, batteryLevel: 0.8))
        XCTAssertTrue(automaticEnergySavingBatteryConditionIsOn(activationThreshold: 15, batteryLevel: 0.1))
    }
}
