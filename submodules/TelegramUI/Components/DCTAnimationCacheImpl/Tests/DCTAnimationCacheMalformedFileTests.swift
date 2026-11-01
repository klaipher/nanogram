import Foundation
import XCTest
import AnimationCache
@testable import DCTAnimationCacheImpl

private typealias Support = DCTAnimationCacheTestSupport

// Offsets of the header fields of a cache file (all little-endian UInt32 / Float32).
private struct FileLayout {
    let widthOffset = 4
    let heightOffset = 8
    let contentLengthOffset: Int
    let frameCountOffset: Int
    let frameCount: Int

    init(data: Data) {
        var offset = 12
        for _ in 0 ..< 3 {
            offset += 4 + Int(readUInt32(data, offset))
        }
        self.contentLengthOffset = offset
        offset += 4 + Int(readUInt32(data, offset))
        self.frameCountOffset = offset
        self.frameCount = Int(readUInt32(data, offset))
    }

    var firstDurationOffset: Int {
        return self.frameCountOffset + 4
    }
}

private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    var value: UInt32 = 0
    _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset ..< offset + 4) }
    return value
}

private func write<T>(_ value: T, to data: inout Data, at offset: Int) {
    var value = value
    withUnsafeBytes(of: &value) { data.replaceSubrange(offset ..< offset + $0.count, with: $0) }
}

// Cache files are read back from disk, so any header value can show up. None may crash the reader.
final class DCTAnimationCacheMalformedFileTests: XCTestCase {
    private var basePath: String!

    override func setUp() {
        super.setUp()
        self.basePath = Support.makeTempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    private func fixture() throws -> Data {
        return try Data(contentsOf: URL(fileURLWithPath: try Support.fixturePath("emoji62_v6")))
    }

    // Loads `data` and plays it through; returns whether the file was accepted.
    private func loadAndPlay(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let path = self.basePath + "/" + UUID().uuidString
        XCTAssertNoThrow(try data.write(to: URL(fileURLWithPath: path)), file: file, line: line)
        guard let item = try? loadItem(path: path) else {
            return false
        }
        for _ in 0 ..< max(2, item.numFrames + 1) {
            let _ = item.advance(advance: .frames(1), requestedFormat: .rgba)
        }
        let _ = item.advance(advance: .duration(1.0 / 30.0), requestedFormat: .yuva(rowAlignment: 1))
        return true
    }

    func testUnmodifiedFixtureLoads() throws {
        XCTAssertTrue(self.loadAndPlay(try self.fixture()))
    }

    // Width and height size the decode buffers: UInt32.max overflowed width * 2 * height, and a size that
    // is not a multiple of 16 has DCT blocks that do not fit the planes.
    func testUnusableDimensionsAreRejected() throws {
        let original = try self.fixture()
        let layout = FileLayout(data: original)
        let sizes: [(UInt32, UInt32)] = [
            (UInt32.max, UInt32.max), (UInt32.max, 64), (64, UInt32.max), (0x8000_0000, 0x8000_0000),
            (65536, 65536), (0, 64), (64, 0), (0, 0), (62, 64), (64, 62), (8, 8), (1, 1), (8192, 16)
        ]
        for (width, height) in sizes {
            var data = original
            write(width, to: &data, at: layout.widthOffset)
            write(height, to: &data, at: layout.heightOffset)
            XCTAssertFalse(self.loadAndPlay(data), "\(width)x\(height)")
        }
    }

    // A file that lists no frames but carries frame data indexed an empty duration table.
    func testFileWithoutFramesIsRejected() throws {
        var data = try self.fixture()
        let layout = FileLayout(data: data)
        XCTAssertGreaterThan(layout.frameCount, 0)
        write(UInt32(0), to: &data, at: layout.frameCountOffset)
        XCTAssertFalse(self.loadAndPlay(data))
    }

    // Zero and negative durations made playback loop forever or advance by a negative frame count,
    // and tiny ones overflowed the frame count computed from them.
    func testUnusableFrameDurationsAreRejected() throws {
        let original = try self.fixture()
        let layout = FileLayout(data: original)
        for duration: Float32 in [.nan, -.nan, 0.0, -0.0, -1.0 / 30.0, -.infinity, .leastNonzeroMagnitude, 1e-30, 1e-6] {
            var data = original
            write(duration, to: &data, at: layout.firstDurationOffset + 4 * (layout.frameCount - 1))
            XCTAssertFalse(self.loadAndPlay(data), "\(duration)")
        }
        // An endless frame (a frame rate of 0 gives 1 / 0) still shows.
        for duration: Float32 in [.infinity, 1.0 / 60.0, 3600.0] {
            var data = original
            write(duration, to: &data, at: layout.firstDurationOffset)
            XCTAssertTrue(self.loadAndPlay(data), "\(duration)")
        }
    }

    // A format 7 file whose first plane says its encoded length is 0. A fresh reader has no
    // sparse buffer yet, and `0 < 0` skipped allocating it, so the reader force-unwrapped nil.
    func testZeroEncodedPlaneLengthIsRejected() throws {
        let original = try self.fixture()
        let layout = FileLayout(data: original)
        let width = Int(readUInt32(original, layout.widthOffset))
        let height = Int(readUInt32(original, layout.heightOffset))
        let lumaLength = width * 2 * height
        let chromaLength = (width / 2) * 2 * (height / 2)

        var payload = Data()
        for value in [UInt32(2 * lumaLength + 2 * chromaLength), 1, UInt32(lumaLength), 0] {
            withUnsafeBytes(of: value) { payload.append(contentsOf: $0) }
        }
        let compressed = try (payload as NSData).compressed(using: .lzfse) as Data

        var data = original.prefix(layout.contentLengthOffset)
        write(UInt32(7), to: &data, at: 0)
        withUnsafeBytes(of: UInt32(compressed.count)) { data.append(contentsOf: $0) }
        data.append(compressed)
        withUnsafeBytes(of: UInt32(1)) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Float32(1.0 / 30.0)) { data.append(contentsOf: $0) }

        let path = self.basePath + "/zero-encoded-length"
        try data.write(to: URL(fileURLWithPath: path))
        let item = try loadItem(path: path)
        XCTAssertNil(item.advance(advance: .frames(1), requestedFormat: .rgba))
    }

    // Every header field set to extreme values, one at a time: never a crash.
    func testExtremeHeaderValuesNeverCrash() throws {
        let original = try self.fixture()
        let layout = FileLayout(data: original)
        let offsets = [0, layout.widthOffset, layout.heightOffset, 12, layout.contentLengthOffset, layout.frameCountOffset]
        for offset in offsets {
            for value: UInt32 in [0, 1, 6, 7, 0x7fff_ffff, 0x8000_0000, UInt32.max] {
                var data = original
                write(value, to: &data, at: offset)
                let _ = self.loadAndPlay(data)
            }
        }
        // Truncated at every header field boundary.
        for length in [0, 3, 4, 11, 12, 13, layout.frameCountOffset, layout.frameCountOffset + 3, layout.firstDurationOffset + 2] {
            let _ = self.loadAndPlay(original.prefix(length))
        }
    }
}
