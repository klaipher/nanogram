import Foundation
import XCTest
import OpusBinding

private struct OggPageInfo {
    let headerType: UInt8
    let serial: UInt32
    let sequence: UInt32
    let granule: Int64

    var isBeginningOfStream: Bool {
        return (self.headerType & 0x02) != 0
    }
}

private func oggPages(_ data: Data) -> [OggPageInfo] {
    let bytes = [UInt8](data)
    var pages: [OggPageInfo] = []
    var offset = 0
    func u32(_ at: Int) -> UInt32 {
        return UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }
    while offset + 27 <= bytes.count {
        guard bytes[offset] == 0x4f, bytes[offset + 1] == 0x67, bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else {
            XCTFail("no capture pattern at \(offset)")
            break
        }
        let granule = Int64(bitPattern: UInt64(u32(offset + 6)) | (UInt64(u32(offset + 10)) << 32))
        let segmentCount = Int(bytes[offset + 26])
        var bodyLength = 0
        for i in 0 ..< segmentCount {
            bodyLength += Int(bytes[offset + 27 + i])
        }
        pages.append(OggPageInfo(headerType: bytes[offset + 5], serial: u32(offset + 14), sequence: u32(offset + 18), granule: granule))
        offset += 27 + segmentCount + bodyLength
    }
    XCTAssertEqual(offset, bytes.count)
    return pages
}

private func sineFrame(index: Int, frequency: Double = 440.0) -> Data {
    var samples = [Int16](repeating: 0, count: 960)
    for i in 0 ..< 960 {
        let t = Double(index * 960 + i) / 48000.0
        samples[i] = Int16(sin(2.0 * Double.pi * frequency * t) * 12000.0)
    }
    return samples.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func write(_ writer: TGOggOpusWriter, frames: Range<Int>) {
    for index in frames {
        var frame = sineFrame(index: index)
        let count = frame.count
        let result = frame.withUnsafeMutableBytes { buffer -> Bool in
            return writer.writeFrame(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(count))
        }
        XCTAssertTrue(result)
    }
}

private func decodeToEnd(_ data: Data) -> (samples: Int, failed: Bool) {
    let path = NSTemporaryDirectory() + "opus_continuity_\(UUID().uuidString).ogg"
    try! data.write(to: URL(fileURLWithPath: path))
    defer {
        try? FileManager.default.removeItem(atPath: path)
    }
    guard let reader = OggOpusReader(path: path) else {
        return (0, true)
    }
    let capacity = 960 * 8
    let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: capacity)
    defer {
        buffer.deallocate()
    }
    var total = 0
    while true {
        let result = reader.read(buffer, bufSize: Int32(capacity))
        if result < 0 {
            return (total, true)
        }
        if result == 0 {
            break
        }
        total += Int(result)
    }
    return (total, false)
}

private func assertSingleLogicalStream(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
    let pages = oggPages(data)
    XCTAssertGreaterThan(pages.count, 2, file: file, line: line)
    XCTAssertEqual(pages.filter(\.isBeginningOfStream).count, 1, "BOS pages", file: file, line: line)
    XCTAssertEqual(Set(pages.map(\.serial)).count, 1, file: file, line: line)
    for (index, page) in pages.enumerated() {
        XCTAssertEqual(page.sequence, UInt32(index), "page sequence at \(index)", file: file, line: line)
    }
}

final class OggOpusWriterContinuityTests: XCTestCase {
    private func uninterruptedSampleCount(frames: Int) -> Int {
        let item = TGDataItem(data: Data())!
        let writer = TGOggOpusWriter()
        XCTAssertTrue(writer.begin(with: item))
        write(writer, frames: 0 ..< frames)
        XCTAssertTrue(writer.writeFrame(nil, frameByteCount: 0))
        assertSingleLogicalStream(item.data())
        let decoded = decodeToEnd(item.data())
        XCTAssertFalse(decoded.failed)
        return decoded.samples
    }

    func testPauseAndResumeKeepOneLogicalStream() {
        let item = TGDataItem(data: Data())!
        let writer = TGOggOpusWriter()
        XCTAssertTrue(writer.begin(with: item))
        write(writer, frames: 0 ..< 50)
        let state = writer.pause()
        XCTAssertTrue(writer.resume(with: item, encoderState: state))
        write(writer, frames: 50 ..< 100)
        XCTAssertTrue(writer.writeFrame(nil, frameByteCount: 0))

        assertSingleLogicalStream(item.data())
        let decoded = decodeToEnd(item.data())
        XCTAssertFalse(decoded.failed, "op_read returned an error")
        XCTAssertEqual(decoded.samples, uninterruptedSampleCount(frames: 100))
    }

    func testResumeFromStateWithoutPageNumberReparsesTheData() {
        let item = TGDataItem(data: Data())!
        let writer = TGOggOpusWriter()
        XCTAssertTrue(writer.begin(with: item))
        write(writer, frames: 0 ..< 50)
        var state = writer.pause()
        state.removeValue(forKey: "pageno")

        let restoredItem = TGDataItem(data: item.data())!
        let restored = TGOggOpusWriter()
        XCTAssertTrue(restored.resume(with: restoredItem, encoderState: state))
        write(restored, frames: 50 ..< 100)
        XCTAssertTrue(restored.writeFrame(nil, frameByteCount: 0))

        assertSingleLogicalStream(restoredItem.data())
        XCTAssertFalse(decodeToEnd(restoredItem.data()).failed)
    }

    func testAppendToFinishedFileKeepsOneLogicalStream() {
        let item = TGDataItem(data: Data())!
        let writer = TGOggOpusWriter()
        XCTAssertTrue(writer.begin(with: item))
        write(writer, frames: 0 ..< 50)
        XCTAssertTrue(writer.writeFrame(nil, frameByteCount: 0))

        let appendItem = TGDataItem(data: item.data())!
        let appender = TGOggOpusWriter()
        XCTAssertTrue(appender.beginAppend(with: appendItem))
        write(appender, frames: 50 ..< 100)
        XCTAssertTrue(appender.writeFrame(nil, frameByteCount: 0))

        assertSingleLogicalStream(appendItem.data())
        let decoded = decodeToEnd(appendItem.data())
        XCTAssertFalse(decoded.failed, "op_read returned an error")
        XCTAssertEqual(decoded.samples, uninterruptedSampleCount(frames: 100))
    }
}
