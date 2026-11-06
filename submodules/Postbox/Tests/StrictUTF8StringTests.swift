import XCTest
@testable import Postbox

/// `StrictUTF8String` replaces `String(data: Data(bytes:count:), encoding: .utf8)` on the message read path. It has
/// to give the same answer for every input, including invalid and byte-order-marked input.
final class StrictUTF8StringTests: XCTestCase {
    private func viaFoundation(_ bytes: [UInt8]) -> String? {
        return bytes.withUnsafeBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress else {
                return String(data: Data(), encoding: .utf8)
            }
            return String(data: Data(bytes: base, count: buffer.count), encoding: .utf8)
        }
    }

    private func viaHelper(_ bytes: [UInt8]) -> String? {
        return bytes.withUnsafeBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress else {
                return StrictUTF8String.decode(UnsafePointer<UInt8>(bitPattern: 1)!, count: 0)
            }
            return StrictUTF8String.decode(base, count: buffer.count)
        }
    }

    private func assertSame(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.viaHelper(bytes), self.viaFoundation(bytes), "\(bytes)", file: file, line: line)
    }

    func testValidTextDecodes() {
        for text in ["", "a", "hello", "Привіт, світе", "日本語のテキスト", "emoji 👨‍👩‍👧‍👦🇺🇦 and e\u{0301}", "line\nbreak\u{0}nul", String(repeating: "x", count: 5000)] {
            self.assertSame(Array(text.utf8))
            XCTAssertEqual(self.viaHelper(Array(text.utf8)), text)
        }
    }

    func testInvalidSequencesGiveNilLikeFoundation() {
        let cases: [[UInt8]] = [
            [0xFF],
            [0x80],
            [0xC0, 0xAF],
            [0xE2, 0x82],
            [0xF0, 0x9F, 0x98],
            [0xED, 0xA0, 0x80],
            [0x61, 0xC3],
            [0x61, 0xC3, 0x28, 0x62],
            [0xE2, 0x82, 0xAC, 0xE2, 0x82]
        ]
        for bytes in cases {
            XCTAssertNil(self.viaHelper(bytes), "\(bytes)")
            self.assertSame(bytes)
        }
    }

    func testTruncatedSequenceThatReplacesToTheSameByteCountIsStillInvalid() {
        let truncatedEuroSign: [UInt8] = [0xE2, 0x82]
        XCTAssertNil(self.viaHelper(truncatedEuroSign))
    }

    func testByteOrderMarkIsHandledLikeFoundation() {
        self.assertSame([0xEF, 0xBB, 0xBF])
        self.assertSame([0xEF, 0xBB, 0xBF, 0x68, 0x69])
        self.assertSame([0xEF, 0xBB])
    }
}
