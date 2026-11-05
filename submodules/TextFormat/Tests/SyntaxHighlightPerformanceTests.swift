import XCTest
import SwiftSignalKit
@testable import TextFormat

/// Highlighting a large code block with the real libprisma engine (a 2400-line Swift listing, about 90 KB), the work a
/// big `pre` block costs the first time it is shown. Measures wall clock, CPU and peak memory.
///
/// Skipped unless TG_PERF=1 (see Postbox/Tests/PostboxReadPerformanceTests.swift for how to run and compare).
final class SyntaxHighlightPerformanceTests: XCTestCase {
    private var listing = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TG_PERF"] == "1", "performance tests run with TG_PERF=1 (tg perf run)")
        let block = """
        import Foundation

        struct Account<Value: Hashable>: Hashable {
            let id: Int
            var values: [Value] = []

            func total(_ weight: Double = 1.5) -> Double {
                var sum = 0.0
                for (index, value) in self.values.enumerated() where index % 2 == 0 {
                    sum += Double(value.hashValue % 97) * weight // a comment
                }
                return sum
            }
        }

        """
        self.listing = String(repeating: block, count: 100)
    }

    func testHighlightLargeSwiftBlock() {
        let spec = CachedMessageSyntaxHighlight.Spec(language: "swift", text: self.listing)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        var entityCount = 0
        self.measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            let expectation = XCTestExpectation(description: "highlight")
            let disposable = asyncStanaloneSyntaxHighlight(current: nil, specs: [spec]).start(next: { value in
                entityCount = value.values[spec]?.entities.count ?? 0
                expectation.fulfill()
            })
            self.wait(for: [expectation], timeout: 60.0)
            disposable.dispose()
        }
        XCTAssertGreaterThan(entityCount, 0, "precondition: libprisma highlights `swift`")
    }
}
