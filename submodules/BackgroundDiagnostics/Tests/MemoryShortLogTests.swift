import XCTest
@testable import BackgroundDiagnostics

final class MemoryShortLogBudgetTests: XCTestCase {
    private let gigabyte: UInt64 = 1024 * 1024 * 1024

    /// Entering the background and memory warnings are logged, but each at most once a minute (a burst of warnings
    /// must not fill the short log).
    func testEventsAreLimitedPerReason() {
        var budget = MemoryShortLogBudget()
        XCTAssertTrue(budget.shouldLogEvent(reason: "background", now: 100.0))
        XCTAssertFalse(budget.shouldLogEvent(reason: "background", now: 130.0))
        XCTAssertTrue(budget.shouldLogEvent(reason: "memory warning", now: 130.0))
        XCTAssertFalse(budget.shouldLogEvent(reason: "memory warning", now: 189.9))
        XCTAssertTrue(budget.shouldLogEvent(reason: "background", now: 160.0))
        XCTAssertTrue(budget.shouldLogEvent(reason: "memory warning", now: 190.0))
    }

    /// A refused event does not move the window: the next line is a minute after the last one written.
    func testRefusedEventDoesNotExtendTheWindow() {
        var budget = MemoryShortLogBudget()
        XCTAssertTrue(budget.shouldLogEvent(reason: "background", now: 0.0))
        XCTAssertFalse(budget.shouldLogEvent(reason: "background", now: 59.0))
        XCTAssertTrue(budget.shouldLogEvent(reason: "background", now: 60.0))
    }

    /// The periodic line is only for a footprint above 1 GB, and at most once every 10 minutes.
    func testPeriodicNeedsHighFootprint() {
        var budget = MemoryShortLogBudget()
        XCTAssertFalse(budget.shouldLogPeriodic(footprint: nil, now: 0.0))
        XCTAssertFalse(budget.shouldLogPeriodic(footprint: 0, now: 0.0))
        XCTAssertFalse(budget.shouldLogPeriodic(footprint: self.gigabyte, now: 0.0))
        XCTAssertTrue(budget.shouldLogPeriodic(footprint: self.gigabyte + 1, now: 0.0))
    }

    func testPeriodicIsLimitedToOnceEveryTenMinutes() {
        var budget = MemoryShortLogBudget()
        let high = 2 * self.gigabyte
        XCTAssertTrue(budget.shouldLogPeriodic(footprint: high, now: 1000.0))
        XCTAssertFalse(budget.shouldLogPeriodic(footprint: high, now: 1005.0))
        XCTAssertFalse(budget.shouldLogPeriodic(footprint: high, now: 1599.0))
        XCTAssertTrue(budget.shouldLogPeriodic(footprint: high, now: 1600.0))
        // A low reading in between neither logs nor resets the window.
        XCTAssertFalse(budget.shouldLogPeriodic(footprint: 100, now: 2300.0))
        XCTAssertTrue(budget.shouldLogPeriodic(footprint: high, now: 2300.0))
    }

    /// Five-second ticks for a day above 1 GB give at most 144 periodic lines.
    func testPeriodicVolumeOverADay() {
        var budget = MemoryShortLogBudget()
        var lines = 0
        var now = 0.0
        while now < 24.0 * 60.0 * 60.0 {
            if budget.shouldLogPeriodic(footprint: 3 * self.gigabyte, now: now) {
                lines += 1
            }
            now += 5.0
        }
        XCTAssertEqual(lines, 144)
    }

    /// The events and the periodic line keep separate windows.
    func testEventDoesNotUseThePeriodicWindow() {
        var budget = MemoryShortLogBudget()
        XCTAssertTrue(budget.shouldLogEvent(reason: "background", now: 10.0))
        XCTAssertTrue(budget.shouldLogPeriodic(footprint: 2 * self.gigabyte, now: 10.0))
    }

    /// A clock that goes backwards (it should not: callers pass the system uptime) does not let lines through.
    func testTimeGoingBackwardsDoesNotLog() {
        var budget = MemoryShortLogBudget()
        XCTAssertTrue(budget.shouldLogEvent(reason: "background", now: 500.0))
        XCTAssertFalse(budget.shouldLogEvent(reason: "background", now: 400.0))
        XCTAssertTrue(budget.shouldLogPeriodic(footprint: 2 * self.gigabyte, now: 500.0))
        XCTAssertFalse(budget.shouldLogPeriodic(footprint: 2 * self.gigabyte, now: 100.0))
    }
}

final class MemoryShortLogLineTests: XCTestCase {
    private let mb: UInt64 = 1024 * 1024

    private func memory(footprint: UInt64) -> ProcessMemory {
        return ProcessMemory(footprint: footprint, footprintPeak: 2100 * self.mb, internalBytes: 1500 * self.mb, compressed: 310 * self.mb, purgeableVolatile: 0, graphics: 120 * self.mb, media: 0, mallocInUse: 1201 * self.mb)
    }

    func testPeriodicLine() {
        let line = MemoryShortLogLine(
            reason: "high",
            memory: self.memory(footprint: 1834 * self.mb),
            headroom: 412 * self.mb,
            topZone: MallocZoneUsage(name: "DefaultMallocZone", bytes: 1100 * self.mb, blocks: 2_100_000)
        )
        XCTAssertEqual(line.text, "Memory high: fp 1834.0 MB, peak 2100.0 MB, malloc 1201.0 MB, compr 310.0 MB, gfx 120.0 MB, headroom 412.0 MB, top DefaultMallocZone 1100.0 MB/2100000 blocks")
    }

    /// A purge line says what "after" measured: the free heap pages handed back, not the Postbox caches, which are
    /// cleared later on another queue.
    func testPurgeLine() {
        let line = MemoryShortLogLine(
            reason: "background",
            memory: self.memory(footprint: 1834 * self.mb),
            footprintBefore: 1900 * self.mb,
            headroom: nil,
            topZone: nil
        )
        XCTAssertEqual(line.text, "Memory background: fp 1900.0 MB -> 1834.0 MB after heap-page return, peak 2100.0 MB, malloc 1201.0 MB, compr 310.0 MB, gfx 120.0 MB")
    }

    func testPurgeLineWithoutAfter() {
        let line = MemoryShortLogLine(reason: "memory warning", memory: nil, footprintBefore: 1900 * self.mb, headroom: 5 * self.mb, topZone: nil)
        XCTAssertEqual(line.text, "Memory memory warning: fp 1900.0 MB before heap-page return, after unavailable, headroom 5.0 MB")
    }

    func testNothingMeasured() {
        let line = MemoryShortLogLine(reason: "launch", memory: nil, headroom: nil, topZone: nil)
        XCTAssertEqual(line.text, "Memory launch: fp unavailable")
    }

    /// The line stays one short line whatever the values: a long zone name is cut, and the longest line fits in
    /// 256 bytes.
    func testLineIsBounded() {
        let huge = 99_999 * self.mb
        let line = MemoryShortLogLine(
            reason: "memory warning",
            memory: ProcessMemory(footprint: huge, footprintPeak: huge, internalBytes: huge, compressed: huge, purgeableVolatile: huge, graphics: huge, media: huge, mallocInUse: huge),
            footprintBefore: huge,
            headroom: huge,
            topZone: MallocZoneUsage(name: String(repeating: "z", count: 300), bytes: huge, blocks: 99_999_999)
        )
        let text = line.text
        XCTAssertLessThanOrEqual(text.utf8.count, 256)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertTrue(text.contains(" " + String(repeating: "z", count: MemoryShortLogLine.maxZoneNameLength) + " "))
        XCTAssertFalse(text.contains(String(repeating: "z", count: MemoryShortLogLine.maxZoneNameLength + 1)))
    }

    /// `collect` reads the live process: the footprint it was given, plus headroom and the largest zone.
    func testCollectReadsTheLargestZone() throws {
        let memory = try XCTUnwrap(ProcessMemory.current())
        let line = MemoryShortLogLine.collect(reason: "launch", memory: memory)
        XCTAssertEqual(line.memory, memory)
        XCTAssertNotNil(line.topZone)
        XCTAssertTrue(line.text.hasPrefix("Memory launch: fp "))
    }
}
