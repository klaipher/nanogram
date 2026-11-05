import XCTest
@testable import UniversalMediaPlayer

final class CompleteResourceFileReaderTests: XCTestCase {
    private let bytes: [UInt8] = (0 ..< 1000).map { UInt8($0 % 251) }

    private func reader(readCalls: UnsafeMutablePointer<Int>? = nil) -> CompleteResourceFileReader {
        let bytes = self.bytes
        return CompleteResourceFileReader(size: Int64(bytes.count), readAt: { buffer, count, offset in
            readCalls?.pointee += 1
            let start = Int(offset)
            let end = min(bytes.count, start + count)
            bytes.withUnsafeBufferPointer { source in
                buffer.copyMemory(from: source.baseAddress!.advanced(by: start), byteCount: end - start)
            }
            return end - start
        })
    }

    private func read(_ reader: CompleteResourceFileReader, offset: Int64, maxCount: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0xAA, count: maxCount)
        let count = buffer.withUnsafeMutableBytes { reader.read(into: $0.baseAddress!, offset: offset, maxCount: maxCount) }
        return Array(buffer[0 ..< count])
    }

    func testReadsTheRequestedRange() {
        let reader = self.reader()
        XCTAssertEqual(self.read(reader, offset: 100, maxCount: 50), Array(self.bytes[100 ..< 150]))
    }

    func testTheLastReadIsClippedToTheFileSize() {
        let reader = self.reader()
        XCTAssertEqual(self.read(reader, offset: 990, maxCount: 64), Array(self.bytes[990 ..< 1000]))
    }

    func testAtAndPastTheEndNothingIsRead() {
        var calls = 0
        let reader = self.reader(readCalls: &calls)
        XCTAssertEqual(self.read(reader, offset: 1000, maxCount: 64), [])
        XCTAssertEqual(self.read(reader, offset: 5000, maxCount: 64), [])
        XCTAssertEqual(self.read(reader, offset: -1, maxCount: 64), [])
        XCTAssertEqual(self.read(reader, offset: 0, maxCount: 0), [])
        XCTAssertEqual(calls, 0)
    }

    func testAFailedReadCountsAsEnd() {
        let reader = CompleteResourceFileReader(size: 100, readAt: { _, _, _ in -1 })
        XCTAssertEqual(self.read(reader, offset: 0, maxCount: 10), [])
    }
}
