import XCTest
@testable import BackgroundDiagnostics

@MainActor
final class OneShotBackgroundTaskTests: XCTestCase {
    /// The "lock" task's shape: a 5 s timer ends it, and so does the system's expiration handler if it fires.
    func testEndedOnceByTimerThenExpiration() {
        var ended: [Int] = []
        var expiration: (@MainActor () -> Void)?
        let task = OneShotBackgroundTask<Int>(end: { ended.append($0) })
        task.begin { handler in
            expiration = handler
            return 7
        }
        XCTAssertTrue(task.isActive)
        task.end()
        expiration?()
        task.end()
        XCTAssertEqual(ended, [7])
        XCTAssertFalse(task.isActive)
    }

    func testEndedOnceByExpirationThenTimer() {
        var ended: [Int] = []
        var expiration: (@MainActor () -> Void)?
        let task = OneShotBackgroundTask<Int>(end: { ended.append($0) })
        task.begin { handler in
            expiration = handler
            return 3
        }
        expiration?()
        task.end()
        XCTAssertEqual(ended, [3])
    }

    func testNotGrantedEndsNothing() {
        var ended: [Int] = []
        let task = OneShotBackgroundTask<Int>(end: { ended.append($0) })
        task.begin { _ in nil }
        task.end()
        XCTAssertFalse(task.isActive)
        XCTAssertEqual(ended, [])
    }

    /// Entering the background again before the first task ended ends that one first.
    func testBeginAgainEndsThePreviousTask() {
        var ended: [Int] = []
        var next = 1
        let task = OneShotBackgroundTask<Int>(end: { ended.append($0) })
        task.begin { _ in defer { next += 1 }; return next }
        task.begin { _ in defer { next += 1 }; return next }
        XCTAssertEqual(ended, [1])
        task.end()
        XCTAssertEqual(ended, [1, 2])
    }
}

@MainActor
final class BackgroundDiagnosticsSchedulerTests: XCTestCase {
    private var clock: Double = 100.0
    private var scheduled: [(delay: Double, block: @MainActor () -> Void)] = []

    private func makeScheduler() -> BackgroundDiagnosticsScheduler {
        return BackgroundDiagnosticsScheduler(delays: [5.0, 60.0], now: { [weak self] in self?.clock ?? 0.0 }, schedule: { [weak self] delay, block in
            self?.scheduled.append((delay, block))
        })
    }

    func testReportsOnceAtEachDelay() {
        let scheduler = self.makeScheduler()
        var reports: [Double] = []
        scheduler.didEnterBackground(isEnabled: true, report: { reports.append($0) })
        XCTAssertEqual(self.scheduled.map(\.delay), [5.0, 60.0])
        self.clock += 5.25
        self.scheduled[0].block()
        // Suspended in between: the second report arrives on resume, late.
        self.clock += 1800.0
        self.scheduled[1].block()
        XCTAssertEqual(reports, [5.25, 1805.25])
    }

    func testNothingWhenLoggingIsOff() {
        let scheduler = self.makeScheduler()
        scheduler.didEnterBackground(isEnabled: false, report: { _ in XCTFail("reported") })
        XCTAssertTrue(self.scheduled.isEmpty)
    }

    func testNothingAfterReturningToTheForeground() {
        let scheduler = self.makeScheduler()
        var reports: [Double] = []
        scheduler.didEnterBackground(isEnabled: true, report: { reports.append($0) })
        scheduler.willEnterForeground()
        self.scheduled.forEach { $0.block() }
        XCTAssertEqual(reports, [])
    }

    /// Only the latest background entry reports.
    func testOnlyTheLatestEntryReports() {
        let scheduler = self.makeScheduler()
        var reports: [String] = []
        scheduler.didEnterBackground(isEnabled: true, report: { _ in reports.append("first") })
        scheduler.willEnterForeground()
        scheduler.didEnterBackground(isEnabled: true, report: { _ in reports.append("second") })
        self.scheduled.forEach { $0.block() }
        XCTAssertEqual(reports, ["second", "second"])
    }
}

final class BackgroundDiagnosticsReportTests: XCTestCase {
    func testProcessMemoryIsReadable() throws {
        let memory = try XCTUnwrap(ProcessMemory.current())
        XCTAssertGreaterThan(memory.footprint, 1024 * 1024)
        XCTAssertGreaterThan(memory.mallocInUse, 0)
        XCTAssertGreaterThanOrEqual(memory.footprintPeak, memory.footprint)
    }

    func testLogLine() {
        let mb: UInt64 = 1024 * 1024
        let report = BackgroundDiagnosticsReport(
            secondsInBackground: 5.04,
            memory: ProcessMemory(footprint: 300 * mb, footprintPeak: 515 * mb, internalBytes: 250 * mb, compressed: 80 * mb, purgeableVolatile: 3 * mb / 2, graphics: 40 * mb, media: 0, mallocInUse: 120 * mb),
            backgroundTimeRemaining: 24.96,
            backgroundTasks: ["background-wakeup"],
            audioSessionActive: false,
            displayLinks: .init(registered: 3, running: 0, driverRunning: false),
            caches: [.init(name: "theme images", bytes: 12 * mb), .init(name: "postbox", bytes: nil)]
        )
        XCTAssertEqual(report.logLine, "Background diagnostic: after 5.0 s; footprint 300.0 MB (peak 515.0 MB, internal 250.0 MB, compressed 80.0 MB, graphics 40.0 MB, media 0.0 MB, purgeable 1.5 MB, malloc 120.0 MB); background time remaining 25.0 s; background tasks [background-wakeup]; audio session inactive; display links 0 running of 3, driver stopped; caches [theme images 12.0 MB, postbox ?]")
    }

    func testNoBackgroundTime() {
        let report = BackgroundDiagnosticsReport(secondsInBackground: 61.0, memory: nil, backgroundTimeRemaining: .greatestFiniteMagnitude, backgroundTasks: [], audioSessionActive: true, displayLinks: nil, caches: [])
        XCTAssertEqual(report.logLine, "Background diagnostic: after 61.0 s; footprint unavailable; background time remaining none; background tasks []; audio session active")
    }
}
