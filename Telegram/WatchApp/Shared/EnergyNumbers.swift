public import Foundation
import Darwin

// CPU and energy numbers from the kernel's own counters, for the iPhone app and the watch app (one source: the
// phone's EnergyNumbers module and the watch target both compile this file). Pure parts first, the sampler last.

/// Process-lifetime counters at one moment. Optional where a device or OS does not report the counter.
public struct EnergyCounters: Equatable, Sendable {
    public var cpuUserSeconds: Double
    public var cpuSystemSeconds: Double
    /// TASK_POWER_INFO_V2 task_energy (Apple silicon only).
    public var taskEnergyNanojoules: UInt64?
    /// proc_pid_rusage RUSAGE_INFO_V4 ri_billed_energy.
    public var billedEnergyNanojoules: UInt64?
    public var instructions: UInt64?
    public var cycles: UInt64?
    public var diskWriteBytes: UInt64?
    /// Package idle wake-ups plus interrupt wake-ups.
    public var wakeups: UInt64?

    public init(cpuUserSeconds: Double = 0, cpuSystemSeconds: Double = 0, taskEnergyNanojoules: UInt64? = nil, billedEnergyNanojoules: UInt64? = nil, instructions: UInt64? = nil, cycles: UInt64? = nil, diskWriteBytes: UInt64? = nil, wakeups: UInt64? = nil) {
        self.cpuUserSeconds = cpuUserSeconds
        self.cpuSystemSeconds = cpuSystemSeconds
        self.taskEnergyNanojoules = taskEnergyNanojoules
        self.billedEnergyNanojoules = billedEnergyNanojoules
        self.instructions = instructions
        self.cycles = cycles
        self.diskWriteBytes = diskWriteBytes
        self.wakeups = wakeups
    }

    /// The counters of a process at exec: every counter exists and is 0.
    public static let zero = EnergyCounters(taskEnergyNanojoules: 0, billedEnergyNanojoules: 0, instructions: 0, cycles: 0, diskWriteBytes: 0, wakeups: 0)
}

public enum EnergyPowerState: String, Codable, Sendable {
    case unplugged
    case charging
    case full
    case unknown

    /// Unknown counts as on battery: a device that cannot tell (a simulator) still gets its numbers compared.
    public var countsAsOnBattery: Bool {
        return self != .charging && self != .full
    }
}

/// Battery, Low Power Mode and thermal state at one moment.
public struct EnergyContext: Equatable, Codable, Sendable {
    public var batteryPercent: Int?
    public var power: EnergyPowerState
    public var lowPowerMode: Bool
    public var thermal: String

    public init(batteryPercent: Int?, power: EnergyPowerState, lowPowerMode: Bool, thermal: String) {
        self.batteryPercent = batteryPercent
        self.power = power
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
    }

    public static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    public var text: String {
        let battery = self.batteryPercent.map { "\($0)%" } ?? "unknown"
        return "battery \(battery) (\(self.power.rawValue)), Low Power Mode \(self.lowPowerMode ? "on" : "off"), thermal \(self.thermal)"
    }
}

/// Sums of the counters over a window. Adds up across launches, so a window that started with a switch change can
/// span app restarts.
public struct EnergyTotals: Codable, Equatable, Sendable {
    public var wallSeconds: Double = 0
    public var onBatterySeconds: Double = 0
    public var cpuUserSeconds: Double = 0
    public var cpuSystemSeconds: Double = 0
    public var taskEnergyNanojoules: UInt64?
    public var billedEnergyNanojoules: UInt64?
    public var instructions: UInt64?
    public var cycles: UInt64?
    public var diskWriteBytes: UInt64?
    public var wakeups: UInt64?

    public init() {
    }

    public var cpuSeconds: Double {
        return self.cpuUserSeconds + self.cpuSystemSeconds
    }

    /// Share of the window the device was not charging, 1 when the window is empty.
    public var onBatteryShare: Double {
        return self.wallSeconds > 0 ? min(1.0, self.onBatterySeconds / self.wallSeconds) : 1.0
    }

    private static func sum(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        default: return (lhs ?? 0) &+ (rhs ?? 0)
        }
    }

    public static func + (lhs: EnergyTotals, rhs: EnergyTotals) -> EnergyTotals {
        var result = EnergyTotals()
        result.wallSeconds = lhs.wallSeconds + rhs.wallSeconds
        result.onBatterySeconds = lhs.onBatterySeconds + rhs.onBatterySeconds
        result.cpuUserSeconds = lhs.cpuUserSeconds + rhs.cpuUserSeconds
        result.cpuSystemSeconds = lhs.cpuSystemSeconds + rhs.cpuSystemSeconds
        result.taskEnergyNanojoules = sum(lhs.taskEnergyNanojoules, rhs.taskEnergyNanojoules)
        result.billedEnergyNanojoules = sum(lhs.billedEnergyNanojoules, rhs.billedEnergyNanojoules)
        result.instructions = sum(lhs.instructions, rhs.instructions)
        result.cycles = sum(lhs.cycles, rhs.cycles)
        result.diskWriteBytes = sum(lhs.diskWriteBytes, rhs.diskWriteBytes)
        result.wakeups = sum(lhs.wakeups, rhs.wakeups)
        return result
    }
}

private func energyGrowth(_ now: UInt64?, _ base: UInt64?) -> UInt64? {
    guard let now, let base, now >= base else {
        return nil
    }
    return now - base
}

extension EnergyCounters {
    /// What grew since `base`. A counter that went down (the process restarted) or is missing on one side is left out.
    public func totals(since base: EnergyCounters, wallSeconds: Double, onBatterySeconds: Double) -> EnergyTotals {
        var result = EnergyTotals()
        result.wallSeconds = max(0, wallSeconds)
        result.onBatterySeconds = max(0, min(onBatterySeconds, result.wallSeconds))
        result.cpuUserSeconds = max(0, self.cpuUserSeconds - base.cpuUserSeconds)
        result.cpuSystemSeconds = max(0, self.cpuSystemSeconds - base.cpuSystemSeconds)
        result.taskEnergyNanojoules = energyGrowth(self.taskEnergyNanojoules, base.taskEnergyNanojoules)
        result.billedEnergyNanojoules = energyGrowth(self.billedEnergyNanojoules, base.billedEnergyNanojoules)
        result.instructions = energyGrowth(self.instructions, base.instructions)
        result.cycles = energyGrowth(self.cycles, base.cycles)
        result.diskWriteBytes = energyGrowth(self.diskWriteBytes, base.diskWriteBytes)
        result.wakeups = energyGrowth(self.wakeups, base.wakeups)
        return result
    }
}

/// One launch of the app: how long it ran and for how long it was off the charger, from the moments the owner
/// reports the battery state.
public final class EnergyRunTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUptime: Double
    private var lastContext: EnergyContext
    private var wallSeconds: Double = 0
    private var onBatterySeconds: Double = 0
    public let startContext: EnergyContext
    public let startCounters: EnergyCounters

    public init(uptime: Double, context: EnergyContext, counters: EnergyCounters = EnergyCounters()) {
        self.lastUptime = uptime
        self.lastContext = context
        self.startContext = context
        self.startCounters = counters
    }

    /// Call when the battery state may have changed and before reading the numbers.
    public func update(uptime: Double, context: EnergyContext) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        let elapsed = max(0, uptime - self.lastUptime)
        self.wallSeconds += elapsed
        if self.lastContext.power.countsAsOnBattery {
            self.onBatterySeconds += elapsed
        }
        self.lastUptime = uptime
        self.lastContext = context
    }

    public var elapsed: (wall: Double, onBattery: Double) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return (self.wallSeconds, self.onBatterySeconds)
    }

    public func totals(counters: EnergyCounters) -> EnergyTotals {
        let elapsed = self.elapsed
        return counters.totals(since: self.startCounters, wallSeconds: elapsed.wall, onBatterySeconds: elapsed.onBattery)
    }
}

/// Per experiment: the numbers of the window that started when its switch last changed. The two states of a switch are
/// kept apart so A and B compare directly; changing a switch starts the new state's window from zero.
public struct EnergyLedger: Codable, Equatable, Sendable {
    /// Experiment -> state at the last launch ("on" or "off").
    public var lastStates: [String: String] = [:]
    /// Experiment -> state -> numbers up to the last save.
    public var totals: [String: [String: EnergyTotals]] = [:]

    public init() {
    }

    public static func stateName(_ on: Bool) -> String {
        return on ? "on" : "off"
    }

    /// Starts a launch. An experiment whose state is unchanged continues its window; a changed one starts from zero.
    /// Returns what each experiment's window already holds.
    public mutating func beginRun(states: [String: Bool]) -> [String: EnergyTotals] {
        var base: [String: EnergyTotals] = [:]
        for (experiment, on) in states {
            let name = EnergyLedger.stateName(on)
            if self.lastStates[experiment] == name {
                base[experiment] = self.totals[experiment]?[name] ?? EnergyTotals()
            } else {
                base[experiment] = EnergyTotals()
                self.totals[experiment, default: [:]][name] = EnergyTotals()
            }
            self.lastStates[experiment] = name
        }
        return base
    }

    public mutating func record(experiment: String, on: Bool, totals: EnergyTotals) {
        self.totals[experiment, default: [:]][EnergyLedger.stateName(on)] = totals
    }
}

// MARK: Text

public func energyDurationText(_ seconds: Double) -> String {
    if seconds >= 3600 {
        return energyDecimal(seconds / 3600) + " h"
    }
    if seconds >= 60 {
        return energyDecimal(seconds / 60) + " min"
    }
    return "\(Int(seconds.rounded())) s"
}

/// Shortest window the rates are shown for; below it a rate says nothing.
public let energyMinimumRateSeconds: Double = 30
/// Below this share of time off the charger, A and B are not comparable.
public let energyOnBatteryComparableShare: Double = 0.9

public func energyDecimal(_ value: Double) -> String {
    guard value.isFinite else {
        return "0.0"
    }
    return String((value * 10).rounded() / 10)
}

/// The numbers of one window in one line each, with rates per minute once the window is long enough.
public func energyTotalsLines(_ totals: EnergyTotals) -> [String] {
    var lines: [String] = []
    let minutes = totals.wallSeconds / 60
    let rates = totals.wallSeconds >= energyMinimumRateSeconds
    var cpu = "CPU time \(energyDecimal(totals.cpuSeconds)) s (user \(energyDecimal(totals.cpuUserSeconds)), system \(energyDecimal(totals.cpuSystemSeconds)))"
    if rates {
        cpu += ", \(energyDecimal(totals.cpuSeconds / totals.wallSeconds * 100))% of one core on average"
    }
    lines.append(cpu)
    if let energy = totals.taskEnergyNanojoules {
        var line = "Task energy \(energyDecimal(Double(energy) / 1e9)) J"
        if rates {
            line += ", \(energyDecimal(Double(energy) / 1e6 / minutes)) mJ per minute"
        }
        lines.append(line)
    } else {
        lines.append("Task energy: not reported on this device")
    }
    if let billed = totals.billedEnergyNanojoules {
        var line = "Billed energy \(energyDecimal(Double(billed) / 1e9)) J"
        if rates {
            line += ", \(energyDecimal(Double(billed) / 1e6 / minutes)) mJ per minute"
        }
        lines.append(line)
    }
    if let instructions = totals.instructions, let cycles = totals.cycles, cycles > 0 {
        lines.append("Instructions \(energyDecimal(Double(instructions) / 1e9)) billion, cycles \(energyDecimal(Double(cycles) / 1e9)) billion (\(energyDecimal(Double(instructions) / Double(cycles))) per cycle)")
    }
    if let writes = totals.diskWriteBytes {
        lines.append("Disk writes \(energyDecimal(Double(writes) / 1048576)) MB")
    }
    if let wakeups = totals.wakeups, rates {
        lines.append("Wake-ups \(energyDecimal(Double(wakeups) / minutes)) per minute")
    }
    return lines
}

/// One short phrase: duration, CPU share and energy rate, with "not comparable" or "too short" when they say little.
public func energyCompactText(_ totals: EnergyTotals) -> String {
    var parts = [energyDurationText(totals.wallSeconds)]
    if totals.wallSeconds >= energyMinimumRateSeconds {
        parts.append("CPU \(energyDecimal(totals.cpuSeconds / totals.wallSeconds * 100))%")
        if let energy = totals.taskEnergyNanojoules {
            parts.append("\(energyDecimal(Double(energy) / 1e6 / (totals.wallSeconds / 60))) mJ/min")
        }
        if totals.onBatteryShare < energyOnBatteryComparableShare {
            parts.append("not comparable (charging \(Int(((1 - totals.onBatteryShare) * 100).rounded()))%)")
        }
    } else {
        parts.append("too short for rates")
    }
    return parts.joined(separator: ", ")
}

/// "Not comparable" note when the window spent much of its time on the charger.
public func energyComparabilityNote(_ totals: EnergyTotals) -> String? {
    if totals.wallSeconds < energyMinimumRateSeconds {
        return "Window too short for rates: keep using the app for at least \(Int(energyMinimumRateSeconds)) seconds."
    }
    if totals.onBatteryShare < energyOnBatteryComparableShare {
        return "Not comparable: the device was charging for \(Int(((1 - totals.onBatteryShare) * 100).rounded()))% of this window."
    }
    return nil
}

/// The lines for one experiment: its state, the window since the switch last changed, and the other state's
/// last numbers for comparison.
public func energyExperimentLines(experiment: String, on: Bool, own: EnergyTotals, other: EnergyTotals?) -> [String] {
    var lines = ["\(experiment) = \(EnergyLedger.stateName(on)): since the switch changed, \(energyDurationText(own.wallSeconds)), \(Int((own.onBatteryShare * 100).rounded()))% of it off the charger"]
    lines.append(contentsOf: energyTotalsLines(own).map { "    " + $0 })
    if let note = energyComparabilityNote(own) {
        lines.append("    " + note)
    }
    if let other, other.wallSeconds > 0 {
        lines.append("  with it \(EnergyLedger.stateName(!on)) (last window): \(energyDurationText(other.wallSeconds)), \(Int((other.onBatteryShare * 100).rounded()))% of it off the charger")
        lines.append(contentsOf: energyTotalsLines(other).map { "    " + $0 })
        if let note = energyComparabilityNote(other) {
            lines.append("    " + note)
        }
    }
    return lines
}

// MARK: Sampler

public enum EnergySampler {
    private typealias ProcPidRusage = @convention(c) (Int32, Int32, UnsafeMutablePointer<rusage_info_v4>) -> Int32

    /// proc_pid_rusage is in libSystem on every Apple platform but its header is only in the macOS SDK, so it is
    /// looked up by name; nil when the system does not have it.
    private static func procPidRusage() -> ProcPidRusage? {
        guard let symbol = unsafe dlsym(unsafe UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage") else {
            return nil
        }
        return unsafe unsafeBitCast(symbol, to: ProcPidRusage.self)
    }

    /// The counters of this process now; nil only when even the CPU time cannot be read.
    public static func read() -> EnergyCounters? {
        var usage = rusage()
        guard unsafe getrusage(RUSAGE_SELF, &usage) == 0 else {
            return nil
        }
        var counters = EnergyCounters()
        counters.cpuUserSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        counters.cpuSystemSeconds = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6

#if arch(arm64) || arch(arm64_32)
        var power = task_power_info_v2_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &power) { pointer in
            unsafe pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                unsafe task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), rebound, &count)
            }
        }
        if result == KERN_SUCCESS {
            counters.taskEnergyNanojoules = power.task_energy
        }
#endif

        if let function = unsafe procPidRusage() {
            var info = rusage_info_v4()
            let status = unsafe function(getpid(), RUSAGE_INFO_V4, &info)
            if status == 0 {
                counters.billedEnergyNanojoules = info.ri_billed_energy
                counters.instructions = info.ri_instructions
                counters.cycles = info.ri_cycles
                counters.diskWriteBytes = info.ri_logical_writes
                counters.wakeups = info.ri_pkg_idle_wkups &+ info.ri_interrupt_wkups
            }
        }
        return counters
    }
}

// MARK: Monitor

/// One app's numbers: this launch, and per switch since it last changed, saved between launches so a switch change
/// shows A against B. The phone keeps one for its performance experiments, the watch one for its feature flags.
public final class EnergyMonitor: @unchecked Sendable {
    private let title: String
    private let defaults: UserDefaults
    private let ledgerKey: String
    private let defaultStates: [String: Bool]
    private let readCounters: @Sendable () -> EnergyCounters?
    private let uptime: @Sendable () -> Double
    private let states: @Sendable () -> [String: Bool]
    private let lock = NSLock()
    private var tracker: EnergyRunTracker?
    private var ledger = EnergyLedger()
    private var bases: [String: EnergyTotals] = [:]

    public init(
        title: String,
        ledgerKey: String,
        defaultStates: [String: Bool],
        defaults: UserDefaults = .standard,
        readCounters: @escaping @Sendable () -> EnergyCounters? = { EnergySampler.read() },
        uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        states: @escaping @Sendable () -> [String: Bool]
    ) {
        self.title = title
        self.ledgerKey = ledgerKey
        self.defaultStates = defaultStates
        self.defaults = defaults
        self.readCounters = readCounters
        self.uptime = uptime
        self.states = states
    }

    /// Once per launch, early: the process counters are zero at launch, so the launch window starts here.
    public func start(context: EnergyContext) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard self.tracker == nil else {
            return
        }
        if let data = self.defaults.data(forKey: self.ledgerKey), let stored = try? JSONDecoder().decode(EnergyLedger.self, from: data) {
            self.ledger = stored
        }
        self.bases = self.ledger.beginRun(states: self.states())
        self.tracker = EnergyRunTracker(uptime: self.uptime(), context: context, counters: .zero)
        self.saveLocked()
    }

    /// Brings the windows up to date and saves them; returns this launch's totals.
    @discardableResult
    public func refresh(context: EnergyContext) -> EnergyTotals {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.refreshLocked(context: context) ?? EnergyTotals()
    }

    private func refreshLocked(context: EnergyContext) -> EnergyTotals? {
        guard let tracker = self.tracker, let counters = self.readCounters() else {
            return nil
        }
        tracker.update(uptime: self.uptime(), context: context)
        let run = tracker.totals(counters: counters)
        for (name, on) in self.states() {
            self.ledger.record(experiment: name, on: on, totals: (self.bases[name] ?? EnergyTotals()) + run)
        }
        self.saveLocked()
        return run
    }

    /// The text of the energy file of a report.
    public func report(context: EnergyContext) -> String {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let run = self.refreshLocked(context: context) else {
            return self.title + "\nNo numbers: the counters could not be read, or the monitor was not started.\n"
        }
        return EnergyMonitor.reportText(title: self.title, run: run, context: context, startContext: self.tracker?.startContext, states: self.states(), ledger: self.ledger, defaultStates: self.defaultStates)
    }

    /// Short lines for a settings screen: the launch, then each switch's window next to the other state's last one.
    public func summaryLines(context: EnergyContext) -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let run = self.refreshLocked(context: context) else {
            return []
        }
        var lines = ["This launch: " + energyCompactText(run)]
        let states = self.states()
        for name in states.keys.sorted() {
            guard let on = states[name] else {
                continue
            }
            var line = "\(name)=\(EnergyLedger.stateName(on)): " + energyCompactText(self.ledger.totals[name]?[EnergyLedger.stateName(on)] ?? EnergyTotals())
            if let other = self.ledger.totals[name]?[EnergyLedger.stateName(!on)], other.wallSeconds > 0 {
                line += "; \(EnergyLedger.stateName(!on)) before: " + energyCompactText(other)
            }
            lines.append(line)
        }
        return lines
    }

    private func saveLocked() {
        if let data = try? JSONEncoder().encode(self.ledger) {
            self.defaults.set(data, forKey: self.ledgerKey)
        }
    }

    /// Pure. Switches still at their default with no window of the other state are listed in one line: their
    /// window is this launch's, or a longer run of the same setting.
    public static func reportText(title: String, run: EnergyTotals, context: EnergyContext, startContext: EnergyContext?, states: [String: Bool], ledger: EnergyLedger, defaultStates: [String: Bool]) -> String {
        var lines = [title]
        lines.append("Rates are per minute of wall-clock time in the window, background and suspended time included.")
        lines.append("Now: " + context.text)
        if let startContext {
            lines.append("At launch: " + startContext.text)
        }
        lines.append("")
        lines.append("This launch: \(energyDurationText(run.wallSeconds)), \(Int((run.onBatteryShare * 100).rounded()))% of it off the charger")
        lines.append(contentsOf: energyTotalsLines(run).map { "    " + $0 })
        if let note = energyComparabilityNote(run) {
            lines.append("    " + note)
        }
        lines.append("")
        lines.append("Switches, each since it last changed:")
        var unchanged: [String] = []
        for name in states.keys.sorted() {
            guard let on = states[name] else {
                continue
            }
            let other = ledger.totals[name]?[EnergyLedger.stateName(!on)]
            let hasOther = (other?.wallSeconds ?? 0) > 0
            if on == defaultStates[name] && !hasOther {
                unchanged.append("\(name)=\(EnergyLedger.stateName(on))")
                continue
            }
            let own = ledger.totals[name]?[EnergyLedger.stateName(on)] ?? EnergyTotals()
            lines.append(contentsOf: energyExperimentLines(experiment: name, on: on, own: own, other: other))
        }
        if !unchanged.isEmpty {
            lines.append("Never changed from the default (their window is the launch numbers above, plus earlier launches with the same setting): " + unchanged.joined(separator: ", "))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
