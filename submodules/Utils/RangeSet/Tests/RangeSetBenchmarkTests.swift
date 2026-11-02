import XCTest
import RangeSet

final class RangeSetBenchmarkTests: XCTestCase {
    func testFetchLikeWorkload() {
        let partSize: Int64 = 128 * 1024
        let parts = 64
        var order = Array(0 ..< parts)
        var generator = SystemRandomNumberGenerator()
        order.shuffle(using: &generator)
        let iterations = 200
        let start = CFAbsoluteTimeGetCurrent()
        var checksum = 0
        for _ in 0 ..< iterations {
            var missing = RangeSet<Int64>(0 ..< Int64(parts) * partSize)
            var completed = RangeSet<Int64>()
            for index in order {
                let range = Int64(index) * partSize ..< Int64(index + 1) * partSize
                missing.remove(contentsOf: range)
                completed.formUnion(RangeSet(range))
                let requested = RangeSet<Int64>(0 ..< Int64(parts / 2) * partSize)
                let available = completed.intersection(requested)
                if available.contains(range.lowerBound) {
                    checksum &+= available.ranges.count
                }
                if missing.intersects(range) {
                    checksum &+= 1
                }
            }
        }
        let perIteration = (CFAbsoluteTimeGetCurrent() - start) * 1000.0 / Double(iterations)
        print("BENCH RangeSet fetch-like: \(String(format: "%.3f", perIteration)) ms per iteration (checksum \(checksum))")
        XCTAssertGreaterThan(checksum, 0)
    }
}
