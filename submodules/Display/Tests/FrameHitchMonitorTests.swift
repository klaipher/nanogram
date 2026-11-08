import XCTest
@testable import Display

/// Debug Settings "Frame hitches: log with main-thread stacks": a frame is a hitch when the display link fires
/// later than the frame the system planned (its own `targetTimestamp - timestamp`), so a ProMotion rate change
/// is not counted, and only the longest stalls get a stack.
final class FrameHitchMonitorTests: XCTestCase {
    private func run(_ stats: inout FrameHitchStats, from t: inout Double, frames: Int, hz: Double) {
        for _ in 0 ..< frames {
            t += 1.0 / hz
            stats.record(timestamp: t, expectedDuration: 1.0 / hz)
        }
    }

    func test_steadyFramesHaveNoHitches() {
        var stats = FrameHitchStats(startTime: 0.0)
        var t = 0.0
        stats.record(timestamp: t, expectedDuration: 1.0 / 120.0)
        self.run(&stats, from: &t, frames: 120, hz: 120.0)
        XCTAssertEqual(stats.frames, 120)
        XCTAssertEqual(stats.hitches, 0)
        XCTAssertEqual(stats.hitchTime, 0.0, accuracy: 0.0001)
    }

    func test_aPlannedRateChangeIsNotAHitch() {
        var stats = FrameHitchStats(startTime: 0.0)
        var t = 0.0
        stats.record(timestamp: t, expectedDuration: 1.0 / 120.0)
        self.run(&stats, from: &t, frames: 30, hz: 120.0)
        self.run(&stats, from: &t, frames: 30, hz: 60.0)
        self.run(&stats, from: &t, frames: 10, hz: 20.0)
        XCTAssertEqual(stats.hitches, 0)
    }

    func test_aStallIsAHitchWithItsExtraTime() {
        var stats = FrameHitchStats(startTime: 0.0)
        var t = 0.0
        stats.record(timestamp: t, expectedDuration: 1.0 / 120.0)
        self.run(&stats, from: &t, frames: 10, hz: 120.0)
        let stallStart = t
        t += 0.050
        let stall = stats.record(timestamp: t, expectedDuration: 1.0 / 120.0)
        self.run(&stats, from: &t, frames: 10, hz: 120.0)
        XCTAssertEqual(stats.hitches, 1)
        XCTAssertEqual(stats.hitchTime, 0.050 - 1.0 / 120.0, accuracy: 0.0001)
        XCTAssertEqual(stats.longestInterval, 0.050, accuracy: 0.0001)
        XCTAssertEqual(stall?.start ?? 0.0, stallStart, accuracy: 0.0001)
        XCTAssertEqual(stall?.end ?? 0.0, t - 10.0 / 120.0, accuracy: 0.0001)
    }

    func test_aOneFrameSlipIsAHitchButGetsNoStack() {
        var stats = FrameHitchStats(startTime: 0.0)
        var t = 0.0
        stats.record(timestamp: t, expectedDuration: 1.0 / 120.0)
        t += 2.0 / 120.0
        let stall = stats.record(timestamp: t, expectedDuration: 1.0 / 120.0)
        XCTAssertEqual(stats.hitches, 1)
        XCTAssertNil(stall, "a single dropped frame at 120 Hz is below the stack threshold")
    }

    func test_onlyTheLongestStallsAreKept() {
        var stats = FrameHitchStats(startTime: 0.0)
        var t = 0.0
        stats.record(timestamp: t, expectedDuration: 1.0 / 120.0)
        for gap in [0.030, 0.090, 0.040, 0.120, 0.060, 0.026] {
            t += gap
            if let stall = stats.record(timestamp: t, expectedDuration: 1.0 / 120.0) {
                stats.keep(stall, limit: 3)
            }
            t += 1.0 / 120.0
            stats.record(timestamp: t, expectedDuration: 1.0 / 120.0)
        }
        XCTAssertEqual(stats.keptStalls.map { Int(($0.end - $0.start) * 1000.0 + 0.5) }, [120, 90, 60])
    }

    func test_aPausedLinkIsNotAHitch() {
        var stats = FrameHitchStats(startTime: 0.0)
        stats.record(timestamp: 0.0, expectedDuration: 1.0 / 120.0)
        stats.record(timestamp: 5.0, expectedDuration: 1.0 / 120.0)
        stats.record(timestamp: 5.0 + 1.0 / 120.0, expectedDuration: 1.0 / 120.0)
        XCTAssertEqual(stats.frames, 1)
        XCTAssertEqual(stats.hitches, 0)
    }

    /// A stall inside one call (the tap that raises the keyboard) is timed directly and logged with the sampler's stack.
    func test_measureLogsASlowCallWithItsStack() {
        var lines: [String] = []
        var samplerStates: [Bool] = []
        FrameHitchMonitor.log = { lines.append($0) }
        FrameHitchMonitor.sampler = { samplerStates.append($0) }
        FrameHitchMonitor.capture = { _, _ in return "capture" as NSString }
        FrameHitchMonitor.report = { _ in return "tree" }
        defer {
            FrameHitchMonitor.isEnabled = false
            FrameHitchMonitor.log = nil
            FrameHitchMonitor.sampler = nil
            FrameHitchMonitor.capture = nil
            FrameHitchMonitor.report = nil
        }
        FrameHitchMonitor.isEnabled = true
        XCTAssertEqual(samplerStates, [true], "the sampler runs while the switch is on")
        let fast = FrameHitchMonitor.shared.measure("keyboardFocusTap") { 1 }
        XCTAssertEqual(fast, 1)
        XCTAssertTrue(lines.isEmpty, "a fast call logs nothing")
        FrameHitchMonitor.shared.measure("keyboardFocusTap") {
            Thread.sleep(forTimeInterval: 0.04)
        }
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertTrue(lines.first?.hasPrefix("Frame hitches: window=keyboardFocusTap syncMs=") == true, lines.first ?? "")
        XCTAssertTrue(lines.last?.hasSuffix("\ntree") == true, lines.last ?? "")
        FrameHitchMonitor.isEnabled = false
        XCTAssertEqual(samplerStates, [true, false])
    }

    func test_summaryLine() {
        var stats = FrameHitchStats(startTime: 10.0)
        var t = 10.0
        stats.record(timestamp: t, expectedDuration: 1.0 / 120.0)
        self.run(&stats, from: &t, frames: 119, hz: 120.0)
        t += 0.050
        stats.record(timestamp: t, expectedDuration: 1.0 / 120.0)
        let line = stats.summary(window: "chatScroll", context: "rowReuse=on")
        XCTAssertTrue(line.hasPrefix("Frame hitches: window=chatScroll frames=120 "), line)
        XCTAssertTrue(line.contains(" hitches=1 "), line)
        XCTAssertTrue(line.contains(" hitchMs=41.7 "), line)
        XCTAssertTrue(line.contains(" longestMs=50.0"), line)
        XCTAssertTrue(line.hasSuffix(" ab=rowReuse=on"), line)
    }
}
