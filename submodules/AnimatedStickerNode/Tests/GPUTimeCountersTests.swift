import Foundation
import XCTest
import AnimationCompression

final class GPUTimeCountersTests: XCTestCase {
    func testBuffersAreCountedByKind() {
        let counters = GPUTimeCounters()
        counters.record(.encode, gpuSeconds: 0.004, now: 1000.0)
        counters.record(.encode, gpuSeconds: 0.006, now: 1000.0)
        counters.record(.render, gpuSeconds: 0.001, now: 1000.0)
        let encode = counters.snapshot(.encode)
        XCTAssertEqual(encode.buffers, 2)
        XCTAssertEqual(encode.failures, 0)
        XCTAssertEqual(encode.gpuSeconds, 0.010, accuracy: 0.000001)
        XCTAssertEqual(encode.maxGpuSeconds, 0.006, accuracy: 0.000001)
        XCTAssertEqual(counters.snapshot(.render).buffers, 1)
    }

    func testABufferThatDidNotCompleteIsAFailureWithoutTime() {
        let counters = GPUTimeCounters()
        counters.record(.encode, gpuSeconds: nil, now: 1000.0)
        counters.record(.encode, gpuSeconds: .nan, now: 1000.0)
        counters.record(.encode, gpuSeconds: -1.0, now: 1000.0)
        let encode = counters.snapshot(.encode)
        XCTAssertEqual(encode.buffers, 3)
        XCTAssertEqual(encode.failures, 3)
        XCTAssertEqual(encode.gpuSeconds, 0.0)
    }

    func testTheReportComesOncePerMinuteAndOnlyWhenSomethingRan() {
        let counters = GPUTimeCounters()
        XCTAssertNil(counters.takeReport(now: 1000.0))
        counters.record(.encode, gpuSeconds: 0.010, now: 1000.0)
        counters.record(.render, gpuSeconds: 0.002, now: 1000.0)
        // The first record already reported (nothing was reported before); the later ones wait a minute.
        counters.record(.render, gpuSeconds: 0.002, now: 1030.0)
        XCTAssertNil(counters.takeReport(now: 1030.0))
        let line = counters.takeReport(now: 1060.0)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("render buffers=2") == true, line ?? "")
        XCTAssertNil(counters.takeReport(now: 1200.0), "nothing ran since the last line")
    }

    func testTheReporterGetsTheLine() {
        let counters = GPUTimeCounters()
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var lines: [String] = []
        }
        let box = Box()
        counters.setReporter({ line in
            box.lock.lock()
            box.lines.append(line)
            box.lock.unlock()
        })
        counters.record(.encode, gpuSeconds: 0.0125, now: 5000.0)
        box.lock.lock()
        let lines = box.lines
        box.lock.unlock()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("encode buffers=1 failed=0 gpuMs=13 maxMs=13") == true, lines.first ?? "")
    }

    func testAClockGoingBackwardsDoesNotSilenceTheReport() {
        let counters = GPUTimeCounters()
        counters.record(.encode, gpuSeconds: 0.001, now: 5000.0)
        counters.record(.encode, gpuSeconds: 0.001, now: 100.0)
        XCTAssertNil(counters.takeReport(now: 100.0), "already reported by the second record")
        XCTAssertEqual(counters.snapshot(.encode).buffers, 2)
    }
}
