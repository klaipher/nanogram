import Foundation
import XCTest
import ImageDCT

final class SparseCoefficientsTests: XCTestCase {
    private func roundTrip(_ values: [Int16], file: StaticString = #filePath, line: UInt = #line) {
        var encoded = [UInt8](repeating: 0xff, count: sparseCoefficientsMaxEncodedLength(values.count))
        let length = values.withUnsafeBufferPointer { sparseCoefficientsEncode($0.baseAddress!, values.count, &encoded) }
        XCTAssertLessThanOrEqual(length, sparseCoefficientsMaxEncodedLength(values.count), file: file, line: line)
        var decoded = [Int16](repeating: 0x7777, count: values.count)
        let ok = decoded.withUnsafeMutableBufferPointer { sparseCoefficientsDecode(encoded, length, $0.baseAddress!, values.count) }
        XCTAssertTrue(ok, file: file, line: line)
        XCTAssertEqual(decoded, values, file: file, line: line)
    }

    func testRoundTrip() {
        var generator = SystemRandomNumberGenerator()
        for count in [1, 7, 8, 9, 15, 16, 17, 64, 1000, 4096, 4099] {
            roundTrip([Int16](repeating: 0, count: count))
            roundTrip((0 ..< count).map { Int16(truncatingIfNeeded: $0 &* 37 &- 500) })
            roundTrip((0 ..< count).map { _ in Int16.random(in: 0 ..< 10, using: &generator) < 9 ? 0 : Int16.random(in: Int16.min ... Int16.max, using: &generator) })
            roundTrip((0 ..< count).map { $0 % 2 == 0 ? Int16.min : Int16.max })
        }
    }

    func testMostlyZeroDataShrinks() {
        var values = [Int16](repeating: 0, count: 4096)
        for i in stride(from: 0, to: values.count, by: 13) {
            values[i] = Int16(i % 200 - 100)
        }
        var encoded = [UInt8](repeating: 0, count: sparseCoefficientsMaxEncodedLength(values.count))
        let length = values.withUnsafeBufferPointer { sparseCoefficientsEncode($0.baseAddress!, values.count, &encoded) }
        XCTAssertLessThan(length, values.count * 2 / 4)
    }

    func testMalformedInputIsRejected() {
        let values: [Int16] = [0, 5, 0, 0, -3, 0, 0, 0, 9, 0, 1]
        var encoded = [UInt8](repeating: 0, count: sparseCoefficientsMaxEncodedLength(values.count))
        let length = values.withUnsafeBufferPointer { sparseCoefficientsEncode($0.baseAddress!, values.count, &encoded) }
        var decoded = [Int16](repeating: 0, count: values.count)

        // Truncated at every position.
        for cut in 0 ..< length {
            XCTAssertFalse(decoded.withUnsafeMutableBufferPointer { sparseCoefficientsDecode(encoded, cut, $0.baseAddress!, values.count) }, "cut \(cut)")
        }
        // Trailing garbage.
        var longer = Array(encoded.prefix(length)) + [0]
        XCTAssertFalse(decoded.withUnsafeMutableBufferPointer { sparseCoefficientsDecode(&longer, longer.count, $0.baseAddress!, values.count) })
        // A bit set past the last value of a partial group.
        var bad = Array(encoded.prefix(length))
        let lastMaskIndex = 1 + 4 // first group: mask + two values
        bad[lastMaskIndex] |= 0x80
        XCTAssertFalse(decoded.withUnsafeMutableBufferPointer { sparseCoefficientsDecode(&bad, bad.count, $0.baseAddress!, values.count) })
        // Decoding into a longer output than was encoded.
        var more = [Int16](repeating: 0, count: values.count + 8)
        XCTAssertFalse(more.withUnsafeMutableBufferPointer { sparseCoefficientsDecode(encoded, length, $0.baseAddress!, values.count + 8) })
    }
}
