import XCTest
import EnergyNumbers

final class EnergyNumbersTests: XCTestCase {
    private let unplugged = EnergyContext(batteryPercent: 80, power: .unplugged, lowPowerMode: false, thermal: "nominal")
    private let charging = EnergyContext(batteryPercent: 80, power: .charging, lowPowerMode: false, thermal: "nominal")

    func testTotalsAreWhatGrewSinceTheBase() {
        let base = EnergyCounters(cpuUserSeconds: 1, cpuSystemSeconds: 0.5, taskEnergyNanojoules: 1_000, instructions: 10, cycles: 20)
        let now = EnergyCounters(cpuUserSeconds: 4, cpuSystemSeconds: 1.5, taskEnergyNanojoules: 4_000_000_000, instructions: 110, cycles: 220)
        let totals = now.totals(since: base, wallSeconds: 60, onBatterySeconds: 60)
        XCTAssertEqual(totals.cpuUserSeconds, 3, accuracy: 0.0001)
        XCTAssertEqual(totals.cpuSeconds, 4, accuracy: 0.0001)
        XCTAssertEqual(totals.taskEnergyNanojoules, 3_999_999_000)
        XCTAssertEqual(totals.instructions, 100)
        XCTAssertNil(totals.billedEnergyNanojoules)
    }

    func testACounterThatWentDownIsLeftOut() {
        let base = EnergyCounters(taskEnergyNanojoules: 500, instructions: 9)
        let now = EnergyCounters(taskEnergyNanojoules: 100, instructions: 20)
        let totals = now.totals(since: base, wallSeconds: 10, onBatterySeconds: 10)
        XCTAssertNil(totals.taskEnergyNanojoules)
        XCTAssertEqual(totals.instructions, 11)
    }

    func testOnBatteryTimeIsNeverMoreThanWallTime() {
        let totals = EnergyCounters().totals(since: EnergyCounters(), wallSeconds: 10, onBatterySeconds: 50)
        XCTAssertEqual(totals.onBatterySeconds, 10)
    }

    func testAddingKeepsMissingCountersMissing() {
        var a = EnergyTotals()
        a.wallSeconds = 10
        a.taskEnergyNanojoules = 5
        var b = EnergyTotals()
        b.wallSeconds = 20
        let sum = a + b
        XCTAssertEqual(sum.wallSeconds, 30)
        XCTAssertEqual(sum.taskEnergyNanojoules, 5)
        XCTAssertNil(sum.cycles)
    }

    func testRunTrackerCountsTimeOffTheCharger() {
        let tracker = EnergyRunTracker(uptime: 100, context: self.unplugged)
        tracker.update(uptime: 160, context: self.charging)
        tracker.update(uptime: 220, context: self.charging)
        let elapsed = tracker.elapsed
        XCTAssertEqual(elapsed.wall, 120, accuracy: 0.0001)
        XCTAssertEqual(elapsed.onBattery, 60, accuracy: 0.0001)
    }

    func testUnknownBatteryStateCountsAsOnBattery() {
        let unknown = EnergyContext(batteryPercent: nil, power: .unknown, lowPowerMode: false, thermal: "nominal")
        let tracker = EnergyRunTracker(uptime: 0, context: unknown)
        tracker.update(uptime: 90, context: unknown)
        XCTAssertEqual(tracker.elapsed.onBattery, 90, accuracy: 0.0001)
    }

    func testChangedSwitchStartsFromZeroAndKeepsTheOtherStateForComparison() {
        var ledger = EnergyLedger()
        var base = ledger.beginRun(states: ["a": false])
        XCTAssertEqual(base["a"], EnergyTotals())
        var off = EnergyTotals()
        off.wallSeconds = 600
        ledger.record(experiment: "a", on: false, totals: off)

        base = ledger.beginRun(states: ["a": false])
        XCTAssertEqual(base["a"]?.wallSeconds, 600, "unchanged switch continues its window")

        base = ledger.beginRun(states: ["a": true])
        XCTAssertEqual(base["a"], EnergyTotals(), "changed switch starts again")
        XCTAssertEqual(ledger.totals["a"]?["off"]?.wallSeconds, 600, "the other state stays for comparison")
        XCTAssertEqual(ledger.lastStates["a"], "on")
    }

    func testLedgerSurvivesEncoding() throws {
        var ledger = EnergyLedger()
        _ = ledger.beginRun(states: ["a": true])
        var totals = EnergyTotals()
        totals.cpuUserSeconds = 2
        totals.cycles = 7
        ledger.record(experiment: "a", on: true, totals: totals)
        let decoded = try JSONDecoder().decode(EnergyLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
    }

    func testShortWindowGetsNoRatesAndAHint() {
        var totals = EnergyTotals()
        totals.wallSeconds = 10
        totals.onBatterySeconds = 10
        totals.cpuUserSeconds = 1
        XCTAssertFalse(energyTotalsLines(totals).joined().contains("of one core"))
        XCTAssertNotNil(energyComparabilityNote(totals))
    }

    func testLongWindowOnBatteryHasRatesAndNoNote() {
        var totals = EnergyTotals()
        totals.wallSeconds = 600
        totals.onBatterySeconds = 600
        totals.cpuUserSeconds = 30
        totals.taskEnergyNanojoules = 6_000_000_000
        let lines = energyTotalsLines(totals)
        XCTAssertTrue(lines[0].contains("5.0% of one core"), lines[0])
        XCTAssertTrue(lines[1].contains("600.0 mJ per minute"), lines[1])
        XCTAssertNil(energyComparabilityNote(totals))
    }

    func testChargingWindowIsMarkedNotComparable() {
        var totals = EnergyTotals()
        totals.wallSeconds = 600
        totals.onBatterySeconds = 150
        XCTAssertEqual(energyComparabilityNote(totals), "Not comparable: the device was charging for 75% of this window.")
    }

    func testExperimentLinesShowBothStates() {
        var own = EnergyTotals()
        own.wallSeconds = 300
        own.onBatterySeconds = 300
        var other = own
        other.cpuUserSeconds = 3
        let lines = energyExperimentLines(experiment: "softwareDecodeThreads", on: true, own: own, other: other)
        XCTAssertTrue(lines[0].hasPrefix("softwareDecodeThreads = on: since the switch changed, 5.0 min, 100% of it off the charger"), lines[0])
        XCTAssertTrue(lines.contains { $0.hasPrefix("  with it off (last window)") })
    }

    func testTaskEnergyAbsentIsSaid() {
        var totals = EnergyTotals()
        totals.wallSeconds = 100
        XCTAssertTrue(energyTotalsLines(totals).contains("Task energy: not reported on this device"))
    }

    func testSamplerReadsCpuTime() {
        guard let counters = EnergySampler.read() else {
            XCTFail("no counters")
            return
        }
        XCTAssertGreaterThan(counters.cpuUserSeconds + counters.cpuSystemSeconds, 0)
    }

    private final class Clock: @unchecked Sendable {
        var uptime: Double = 1000
        var counters = EnergyCounters()
    }

    private func suite() -> UserDefaults {
        let name = "energy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func monitor(_ defaults: UserDefaults, _ states: [String: Bool], _ clock: Clock) -> EnergyMonitor {
        return EnergyMonitor(title: "Test numbers", ledgerKey: "ledger", defaultStates: ["a": false], defaults: defaults, readCounters: { clock.counters }, uptime: { clock.uptime }, states: { states })
    }

    func testMonitorLaunchTotalsFollowTheCountersAndTheClock() {
        let clock = Clock()
        let monitor = self.monitor(self.suite(), ["a": false], clock)
        monitor.start(context: self.unplugged)
        clock.uptime = 1120
        clock.counters = EnergyCounters(cpuUserSeconds: 12, taskEnergyNanojoules: 2_000_000_000)
        let run = monitor.refresh(context: self.unplugged)
        XCTAssertEqual(run.wallSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(run.cpuUserSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(run.taskEnergyNanojoules, 2_000_000_000)
    }

    func testMonitorKeepsTheOtherStateAcrossLaunches() {
        let defaults = self.suite()
        let first = Clock()
        let launch1 = self.monitor(defaults, ["a": false], first)
        launch1.start(context: self.unplugged)
        first.uptime = 1600
        first.counters = EnergyCounters(cpuUserSeconds: 30)
        launch1.refresh(context: self.unplugged)

        let second = Clock()
        let launch2 = self.monitor(defaults, ["a": true], second)
        launch2.start(context: self.unplugged)
        second.uptime = 1200
        second.counters = EnergyCounters(cpuUserSeconds: 4)
        let text = launch2.report(context: self.unplugged)
        XCTAssertTrue(text.hasPrefix("Test numbers"), text)
        XCTAssertTrue(text.contains("a = on: since the switch changed, 3.3 min"), text)
        XCTAssertTrue(text.contains("with it off (last window): 10.0 min"), text)
    }

    func testUnchangedDefaultSwitchesAreListedInOneLine() {
        let text = EnergyMonitor.reportText(title: "T", run: EnergyTotals(), context: self.unplugged, startContext: self.unplugged, states: ["a": false, "b": false], ledger: EnergyLedger(), defaultStates: ["a": false, "b": false])
        XCTAssertTrue(text.contains("a=off, b=off"), text)
    }

    func testMonitorWithoutStartSaysSo() {
        let monitor = self.monitor(self.suite(), [:], Clock())
        XCTAssertTrue(monitor.report(context: self.unplugged).contains("No numbers"))
    }

    func testCompactTextHasRatesOnlyForLongWindows() {
        var totals = EnergyTotals()
        totals.wallSeconds = 600
        totals.onBatterySeconds = 600
        totals.cpuUserSeconds = 30
        totals.taskEnergyNanojoules = 6_000_000_000
        XCTAssertEqual(energyCompactText(totals), "10.0 min, CPU 5.0%, 600.0 mJ/min")
        totals.wallSeconds = 10
        XCTAssertEqual(energyCompactText(totals), "10 s, too short for rates")
    }

    func testMonitorSummaryNamesBothStates() {
        let defaults = self.suite()
        let first = Clock()
        let launch1 = self.monitor(defaults, ["a": false], first)
        launch1.start(context: self.unplugged)
        first.uptime = 1600
        first.counters = EnergyCounters(cpuUserSeconds: 30)
        launch1.refresh(context: self.unplugged)
        let second = Clock()
        let launch2 = self.monitor(defaults, ["a": true], second)
        launch2.start(context: self.unplugged)
        second.uptime = 1120
        second.counters = EnergyCounters(cpuUserSeconds: 6)
        let lines = launch2.summaryLines(context: self.unplugged)
        XCTAssertEqual(lines[0], "This launch: 2.0 min, CPU 5.0%")
        XCTAssertTrue(lines[1].hasPrefix("a=on: 2.0 min, CPU 5.0%; off before: 10.0 min, CPU 5.0%"), lines[1])
    }
}
