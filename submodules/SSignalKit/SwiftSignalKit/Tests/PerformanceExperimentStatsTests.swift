import XCTest
import SwiftSignalKit

final class PerformanceExperimentStatsTests: XCTestCase {
    private func makeFlags() throws -> ExperimentalPerformanceFlags {
        let name = "PerformanceExperimentStatsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return ExperimentalPerformanceFlags(defaults: defaults)
    }

    func testRecordsCountAverageAndMax() {
        let stats = PerformanceExperimentStats()
        stats.record(.av1FrameDecode, seconds: 0.010)
        stats.record(.av1FrameDecode, seconds: 0.030)
        let summary = stats.summary(.av1FrameDecode)
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.averageSeconds, 0.020, accuracy: 0.000001)
        XCTAssertEqual(summary.maxSeconds, 0.030, accuracy: 0.000001)
        XCTAssertEqual(stats.summary(.scrubPreviewFrame).count, 0)
    }

    func testNegativeAndNonFiniteDurationsAreIgnored() {
        let stats = PerformanceExperimentStats()
        stats.record(.threadPoolQueueWait, seconds: -1)
        stats.record(.threadPoolQueueWait, seconds: .nan)
        XCTAssertEqual(stats.summary(.threadPoolQueueWait).count, 0)
    }

    func testSummaryLinesNameStateAndNumbers() throws {
        let flags = try makeFlags()
        flags.setOverride(.softwareDecodeThreads, true)
        let stats = PerformanceExperimentStats()
        stats.record(.av1FrameDecode, seconds: 0.0125)
        let lines = stats.summaryLines(flags: flags)
        XCTAssertEqual(lines.count, PerformanceExperiment.allCases.count)
        XCTAssertEqual(lines[0], "threadPoolQualityOfService=off threadPoolQueueWait: no samples")
        XCTAssertEqual(lines[1], "softwareDecodeThreads=on av1FrameDecode: n=1 avg=12.5 ms max=12.5 ms")
    }

    func testLinesReportTheStateAtLaunchNotTheSwitchFlippedSince() throws {
        let suite = "PerformanceExperimentStatsTests.launch"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(false, forKey: PerformanceExperiment.threadPoolQualityOfService.defaultsKey)
        let flags = ExperimentalPerformanceFlags(defaults: defaults)
        defaults.set(true, forKey: PerformanceExperiment.threadPoolQualityOfService.defaultsKey)
        let lines = PerformanceExperimentStats().summaryLines(flags: flags)
        XCTAssertEqual(lines[0], "threadPoolQualityOfService=off threadPoolQueueWait: no samples")
    }

    func testResetClearsTheNumbers() {
        let stats = PerformanceExperimentStats()
        stats.record(.scrubPreviewFrame, seconds: 0.1)
        stats.reset()
        XCTAssertEqual(stats.summary(.scrubPreviewFrame).count, 0)
    }

    func testReportStartsWithTheDevice() throws {
        let report = performanceExperimentsReport(modelIdentifier: "iPhone15,2", flags: try makeFlags(), stats: PerformanceExperimentStats())
        XCTAssertTrue(report.hasPrefix("Performance experiments (device iPhone15,2)\n"))
    }
}
