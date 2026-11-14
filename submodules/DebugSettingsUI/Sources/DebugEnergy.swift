import Foundation
import UIKit
import SwiftSignalKit
import EnergyNumbers
import WatchReport

/// The app's CPU and energy numbers: this launch, and per performance experiment since its switch last changed
/// (a changed switch only takes effect after a relaunch, so a launch is the unit; the numbers of the other state stay
/// for comparison). The kernel counters are those of the main app process; extensions are not counted.
enum DebugEnergy {
    static let monitor = EnergyMonitor(
        title: "Nanogram iOS energy and CPU numbers (the main app process only; extensions are not counted)",
        ledgerKey: "nanogram.energyLedger",
        defaultStates: Dictionary(uniqueKeysWithValues: PerformanceExperiment.allCases.map { ($0.rawValue, false) }),
        states: { Dictionary(uniqueKeysWithValues: PerformanceExperiment.allCases.map { ($0.rawValue, ExperimentalPerformanceFlags.shared.launchState($0)) }) }
    )

    private static let cache = Atomic<EnergyContext>(value: EnergyContext(batteryPercent: nil, power: .unknown, lowPowerMode: false, thermal: "unknown"))

    /// Battery, Low Power Mode and thermal state now. The battery part is read on the main thread only (UIDevice) and
    /// cached; the rest is read where it is asked for.
    static func currentContext() -> EnergyContext {
        var context = cache.with { $0 }
        context.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        context.thermal = EnergyContext.thermalName(ProcessInfo.processInfo.thermalState)
        return context
    }

    @MainActor
    private static func updateBattery() {
        let device = UIDevice.current
        let power: EnergyPowerState
        switch device.batteryState {
        case .unplugged: power = .unplugged
        case .charging: power = .charging
        case .full: power = .full
        default: power = .unknown
        }
        let level = device.batteryLevel
        let percent: Int? = level >= 0 ? Int((level * 100).rounded()) : nil
        let context = EnergyContext(batteryPercent: percent, power: power, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: EnergyContext.thermalName(ProcessInfo.processInfo.thermalState))
        let _ = cache.swap(context)
        monitor.refresh(context: currentContext())
    }

    @MainActor
    static func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBattery()
        monitor.start(context: currentContext())
        for name in [UIDevice.batteryStateDidChangeNotification, UIDevice.batteryLevelDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    updateBattery()
                }
            }
        }
    }

    /// Short lines for the Debug Settings info row.
    static func summaryLines() -> [String] {
        return ["Now: " + currentContext().text] + monitor.summaryLines(context: currentContext())
    }
}

/// Started once from the main app's launch: begins the energy numbers and the link that receives the watch's reports.
public func startDebugDiagnostics() {
    let start = {
        MainActor.assumeIsolated {
            DebugEnergy.start()
        }
        WatchReportClient.shared.start()
    }
    if Thread.isMainThread {
        start()
    } else {
        DispatchQueue.main.async(execute: start)
    }
}
