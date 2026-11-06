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

    /// A state that carries the encoder (`encoderData`) but no `pageno` is not a state this writer produced: the restore
    /// refuses it instead of guessing the next page number (upstream 13.2's `restoreState` validates every key).
    func testResumeFromStateWithEncoderButWithoutPageNumberIsRefused() {
        let item = TGDataItem(data: Data())!
        let writer = TGOggOpusWriter()
        XCTAssertTrue(writer.begin(with: item))
        write(writer, frames: 0 ..< 50)
        var state = writer.pause()
        state.removeValue(forKey: "pageno")

        let restoredItem = TGDataItem(data: item.data())!
        let restored = TGOggOpusWriter()
        XCTAssertFalse(restored.resume(with: restoredItem, encoderState: state))
    }

    /// A state of the older kind (no encoder, no opus version; only the byte count of what was written) is resumed by
    /// reparsing the data and appending, which keeps one logical stream.
    func testResumeFromStateWithoutEncoderDataReparsesTheData() {
        let item = TGDataItem(data: Data())!
        let writer = TGOggOpusWriter()
        XCTAssertTrue(writer.begin(with: item))
        write(writer, frames: 0 ..< 50)
        var state = writer.pause()
        state.removeValue(forKey: "encoderData")
        state.removeValue(forKey: "opusVersion")
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

private func decodedSamples(_ data: Data) -> [Int16] {
    let path = NSTemporaryDirectory() + "opus_samples_\(UUID().uuidString).ogg"
    try! data.write(to: URL(fileURLWithPath: path))
    defer {
        try? FileManager.default.removeItem(atPath: path)
    }
    guard let reader = OggOpusReader(path: path) else {
        return []
    }
    var result: [Int16] = []
    var buffer = [Int16](repeating: 0, count: 960 * 8)
    while true {
        let count = buffer.withUnsafeMutableBytes { reader.read($0.baseAddress!, bufSize: Int32(960 * 8)) }
        if count <= 0 {
            break
        }
        result.append(contentsOf: buffer[0 ..< Int(count)])
    }
    return result
}

final class OggOpusWriterLiveEncoderTests: XCTestCase {
    private func encode(_ body: (TGOggOpusWriter, TGDataItem) -> Void) -> [Int16] {
        let item = TGDataItem(data: Data())!
        let writer = TGOggOpusWriter()
        XCTAssertTrue(writer.begin(with: item))
        body(writer, item)
        XCTAssertTrue(writer.writeFrame(nil, frameByteCount: 0))
        assertSingleLogicalStream(item.data())
        return decodedSamples(item.data())
    }

    func testPausingTheLiveWriterLeavesTheAudioUntouched() {
        let uninterrupted = self.encode { writer, _ in
            write(writer, frames: 0 ..< 100)
        }
        let pausedLive = self.encode { writer, _ in
            write(writer, frames: 0 ..< 50)
            _ = writer.pause()
            write(writer, frames: 50 ..< 100)
        }
        XCTAssertEqual(pausedLive.count, uninterrupted.count)
        let join = 50 * 960
        let window = (join - 960) ..< min(join + 960 * 2, uninterrupted.count)
        let difference = window.map { abs(Int(pausedLive[$0]) - Int(uninterrupted[$0])) }.max() ?? 0
        XCTAssertLessThan(difference, 100, "a flush-only pause must not disturb the join beyond the encoder's run-to-run noise")
    }

    func testRestoringTheEncoderOnResumeChangesTheJoin() {
        let uninterrupted = self.encode { writer, _ in
            write(writer, frames: 0 ..< 100)
        }
        let restored = self.encode { writer, item in
            write(writer, frames: 0 ..< 50)
            let state = writer.pause()
            XCTAssertTrue(writer.resume(with: item, encoderState: state))
            write(writer, frames: 50 ..< 100)
        }
        XCTAssertEqual(restored.count, uninterrupted.count)
        let join = 50 * 960
        let window = (join - 960) ..< min(join + 960 * 2, uninterrupted.count)
        let difference = window.map { abs(Int(restored[$0]) - Int(uninterrupted[$0])) }.max() ?? 0
        XCTAssertGreaterThan(difference, 500, "a cold encoder at the join is audible; the recorder keeps the live one")
    }
}
