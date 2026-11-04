import Foundation
import XCTest
@testable import Postbox

final class PostboxCodingKeyAndStringTests: XCTestCase {
    private func stringField(key: [UInt8], value: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [UInt8(key.count)]
        result.append(contentsOf: key)
        result.append(UInt8(ValueType.String.rawValue))
        var length = Int32(value.count).littleEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(contentsOf: value)
        return result
    }

    private func int32Field(key: [UInt8], value: Int32) -> [UInt8] {
        var result: [UInt8] = [UInt8(key.count)]
        result.append(contentsOf: key)
        result.append(UInt8(ValueType.Int32.rawValue))
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { result.append(contentsOf: $0) }
        return result
    }

    private func decoder(_ bytes: [UInt8]) -> PostboxDecoder {
        let buffer = WriteBuffer()
        var copy = bytes
        buffer.write(&copy, offset: 0, length: copy.count)
        return PostboxDecoder(buffer: MemoryBuffer(data: buffer.makeData()))
    }

    func testEncodedBytesAreUnchanged() {
        let encoder = PostboxEncoder()
        encoder.encodeString("hello", forKey: "t")
        encoder.encodeInt32(42, forKey: "longerKey")
        encoder.encodeString("ü€😀", forKey: "ключ")
        encoder.encodeString("", forKey: "e")

        var expected: [UInt8] = []
        expected += self.stringField(key: Array("t".utf8), value: Array("hello".utf8))
        expected += self.int32Field(key: Array("longerKey".utf8), value: 42)
        expected += self.stringField(key: Array("ключ".utf8), value: Array("ü€😀".utf8))
        expected += self.stringField(key: Array("e".utf8), value: [])
        XCTAssertEqual(Array(encoder.makeData()), expected)
    }

    func testKeysAreFoundInAnyOrderAndMissingOnesAreNot() {
        let encoder = PostboxEncoder()
        encoder.encodeInt32(1, forKey: "a")
        encoder.encodeInt32(2, forKey: "ab")
        encoder.encodeString("x", forKey: "ключ")
        encoder.encodeInt32(4, forKey: "b")
        let decoder = PostboxDecoder(buffer: encoder.memoryBuffer())
        XCTAssertEqual(decoder.decodeInt32ForKey("b", orElse: 0), 4)
        XCTAssertEqual(decoder.decodeInt32ForKey("a", orElse: 0), 1)
        XCTAssertEqual(decoder.decodeOptionalStringForKey("ключ"), "x")
        XCTAssertEqual(decoder.decodeInt32ForKey("ab", orElse: 0), 2)
        XCTAssertNil(decoder.decodeOptionalInt32ForKey("ba"))
        XCTAssertNil(decoder.decodeOptionalInt32ForKey("abc"))
        XCTAssertNil(decoder.decodeOptionalStringForKey("a"))
        XCTAssertEqual(decoder.decodeInt32ForKey("a", orElse: 0), 1)
    }

    func testInvalidUtf8DecodesAsMissing() {
        for invalid: [UInt8] in [[0xFF], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0x61, 0xE2, 0x82]] {
            let bytes = self.stringField(key: Array("s".utf8), value: invalid)
            XCTAssertNil(self.decoder(bytes).decodeOptionalStringForKey("s"), "\(invalid)")
            XCTAssertEqual(self.decoder(bytes).decodeStringForKey("s", orElse: "fallback"), "fallback", "\(invalid)")
        }
    }

    func testLeadingByteOrderMarkIsDroppedAsBefore() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let leading = self.stringField(key: Array("s".utf8), value: bom + Array("abc".utf8))
        XCTAssertEqual(self.decoder(leading).decodeOptionalStringForKey("s"), "abc")
        XCTAssertEqual(self.decoder(leading).decodeStringForKey("s", orElse: ""), "abc")
        let inner = self.stringField(key: Array("s".utf8), value: Array("a".utf8) + bom)
        XCTAssertEqual(self.decoder(inner).decodeOptionalStringForKey("s").map { Array($0.utf8) }, Array("a".utf8) + bom)
        let nul = self.stringField(key: Array("s".utf8), value: [0x61, 0x00, 0x62])
        XCTAssertEqual(self.decoder(nul).decodeOptionalStringForKey("s").map { Array($0.utf8) }, [0x61, 0x00, 0x62])
    }

    func testBenchmarkThirtyFieldObject() {
        let keys = (0 ..< 30).map { "field\($0)" }
        let encoder = PostboxEncoder()
        for (index, key) in keys.enumerated() {
            if index % 2 == 0 {
                encoder.encodeString("value number \(index) with some text", forKey: key)
            } else {
                encoder.encodeInt32(Int32(index), forKey: key)
            }
        }
        let buffer = encoder.memoryBuffer()
        let iterations = 20_000
        var checksum = 0
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< iterations {
            let decoder = PostboxDecoder(buffer: buffer)
            for (index, key) in keys.enumerated() {
                if index % 2 == 0 {
                    checksum &+= decoder.decodeStringForKey(key, orElse: "").utf8.count
                } else {
                    checksum &+= Int(decoder.decodeInt32ForKey(key, orElse: 0))
                }
            }
            let reencoder = PostboxEncoder()
            for key in keys {
                reencoder.encodeInt32(1, forKey: key)
            }
            checksum &+= reencoder.makeData().count
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("BENCH PostboxCoding 30-field decode+encode: \(String(format: "%.2f", elapsed / Double(iterations) * 1_000_000)) us/object (checksum \(checksum))")
        XCTAssertGreaterThan(checksum, 0)
    }
}
