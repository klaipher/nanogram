import XCTest
import RangeSet

/// Differential tests: every operation is checked against a bitmap over 0..<N. They pin the
/// behaviour across the @inlinable rewrite (clients now compile RangeSet's code themselves).
final class RangeSetTests: XCTestCase {
    private static let n = 96

    private struct Model: Equatable {
        var bits = [Bool](repeating: false, count: RangeSetTests.n)

        init() {}

        init<B: BinaryInteger>(_ set: RangeSet<B>) {
            for range in set.ranges {
                for i in Int(range.lowerBound) ..< Int(range.upperBound) {
                    self.bits[i] = true
                }
            }
        }

        mutating func set(_ range: Range<Int>, _ value: Bool) {
            for i in range {
                self.bits[i] = value
            }
        }

        var ranges: [Range<Int>] {
            var result: [Range<Int>] = []
            var start: Int?
            for i in 0 ... self.bits.count {
                let on = i < self.bits.count && self.bits[i]
                if on, start == nil {
                    start = i
                } else if !on, let s = start {
                    result.append(s ..< i)
                    start = nil
                }
            }
            return result
        }
    }

    private struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            self.state &+= 0x9e3779b97f4a7c15
            var z = self.state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
    }

    private func randomRange(_ rng: inout Rng) -> Range<Int> {
        let a = Int.random(in: 0 ... RangeSetTests.n, using: &rng)
        let b = Int.random(in: 0 ... RangeSetTests.n, using: &rng)
        return min(a, b) ..< max(a, b)
    }

    private func canonical<B: BinaryInteger>(_ set: RangeSet<B>) -> [Range<Int>] {
        return set.ranges.map { Int($0.lowerBound) ..< Int($0.upperBound) }
    }

    private func randomSet<B: BinaryInteger>(_ rng: inout Rng, _ type: B.Type) -> (RangeSet<B>, Model) {
        var set = RangeSet<B>()
        var model = Model()
        for _ in 0 ..< Int.random(in: 0 ..< 6, using: &rng) {
            let r = self.randomRange(&rng)
            if Bool.random(using: &rng) {
                set.insert(contentsOf: B(r.lowerBound) ..< B(r.upperBound))
                model.set(r, true)
            } else {
                set.remove(contentsOf: B(r.lowerBound) ..< B(r.upperBound))
                model.set(r, false)
            }
        }
        return (set, model)
    }

    private func check<B: BinaryInteger>(_ type: B.Type, seed: UInt64) {
        var rng = Rng(state: seed)
        for _ in 0 ..< 400 {
            let (a, ma) = self.randomSet(&rng, type)
            let (b, mb) = self.randomSet(&rng, type)
            XCTAssertEqual(self.canonical(a), ma.ranges)
            XCTAssertEqual(Model(a), ma)

            var union = Model()
            var inter = Model()
            var diff = Model()
            var sym = Model()
            for i in 0 ..< RangeSetTests.n {
                union.bits[i] = ma.bits[i] || mb.bits[i]
                inter.bits[i] = ma.bits[i] && mb.bits[i]
                diff.bits[i] = ma.bits[i] && !mb.bits[i]
                sym.bits[i] = ma.bits[i] != mb.bits[i]
            }
            XCTAssertEqual(self.canonical(a.union(b)), union.ranges)
            XCTAssertEqual(self.canonical(a.intersection(b)), inter.ranges)
            XCTAssertEqual(self.canonical(a.subtracting(b)), diff.ranges)
            XCTAssertEqual(self.canonical(a.symmetricDifference(b)), sym.ranges)
            var formed = a
            formed.formUnion(b)
            XCTAssertEqual(self.canonical(formed), union.ranges)
            formed = a
            formed.formIntersection(b)
            XCTAssertEqual(self.canonical(formed), inter.ranges)
            formed = a
            formed.subtract(b)
            XCTAssertEqual(self.canonical(formed), diff.ranges)

            let subset = !(0 ..< RangeSetTests.n).contains { ma.bits[$0] && !mb.bits[$0] }
            XCTAssertEqual(a.isSubset(of: b), subset)
            XCTAssertEqual(b.isSuperset(of: a), subset)
            XCTAssertEqual(a.isStrictSubset(of: b), subset && ma != mb)
            XCTAssertEqual(a == b, ma == mb)
            XCTAssertEqual(a.isEmpty, !ma.bits.contains(true))

            for i in 0 ..< RangeSetTests.n {
                XCTAssertEqual(a.contains(B(i)), ma.bits[i])
            }
            // `intersects` also reports a range that only touches one of the set's ranges
            // (0..<5 and 5..<8). That is how this RangeSet has always behaved; it is pinned here,
            // not endorsed.
            let probe = self.randomRange(&rng)
            let intersects = !probe.isEmpty && ma.ranges.contains { $0.upperBound >= probe.lowerBound && $0.lowerBound <= probe.upperBound }
            XCTAssertEqual(a.intersects(B(probe.lowerBound) ..< B(probe.upperBound)), intersects, "\(self.canonical(a)) \(probe)")
        }
    }

    func testInt64OperationsMatchABitmap() {
        self.check(Int64.self, seed: 1)
        self.check(Int64.self, seed: 2)
    }

    // RangeSet<Int> stores a single range in a packed representation of its own.
    func testIntOperationsMatchABitmap() {
        self.check(Int.self, seed: 3)
        self.check(Int.self, seed: 4)
    }

    func testEqualityIgnoresStorageRepresentation() {
        var a = RangeSet<Int>(2 ..< 5)
        a.insert(contentsOf: 10 ..< 12)
        a.remove(contentsOf: 10 ..< 12)
        XCTAssertEqual(a, RangeSet<Int>(2 ..< 5))
        var empty = RangeSet<Int>(1 ..< 2)
        empty.remove(contentsOf: 1 ..< 2)
        XCTAssertEqual(empty, RangeSet<Int>())
        XCTAssertEqual(RangeSet<Int>([3 ..< 4, 4 ..< 6]).ranges.map { $0 }, [3 ..< 6])
        XCTAssertEqual(RangeSet<Int>(3 ..< 6).hashValue, RangeSet<Int>([3 ..< 4, 4 ..< 6]).hashValue)
        XCTAssertEqual(RangeSet<Int64>([0 ..< 2, 5 ..< 7]).description, "RangeSet(0..<2, 5..<7)")
    }

    func testCollectionHelpers() {
        let text = Array("a#b##c")
        XCTAssertEqual(text.subranges(of: "#").ranges.map { $0 }, [1 ..< 2, 3 ..< 5])
        var numbers = Array(0 ..< 10)
        numbers.removeSubranges(RangeSet([2 ..< 4, 7 ..< 8]))
        XCTAssertEqual(numbers, [0, 1, 4, 5, 6, 8, 9])
    }
}
