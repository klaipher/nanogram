import XCTest
import Postbox
import FlatBuffers
import TelegramApi
@testable import TelegramCore

// A video's duration is a double chosen by its sender, and the chat converts it with
// Int32(duration) while laying out the message. NaN, infinity or a value outside Int32 trapped
// there on every render, so every way a duration enters TelegramMediaFileAttribute keeps it in range.
final class VideoDurationSanitizationTests: XCTestCase {
    private let badValues: [Double] = [.nan, .infinity, -.infinity, 1e20, -5.0, Double(Int32.max) + 10.0]

    private func video(_ duration: Double) -> TelegramMediaFileAttribute {
        return .Video(duration: duration, size: PixelDimensions(width: 1, height: 1), flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil)
    }

    private func duration(_ attribute: TelegramMediaFileAttribute) -> Double? {
        if case let .Video(duration, _, _, _, _, _) = attribute {
            return duration
        }
        return nil
    }

    private func assertConvertible(_ value: Double?, file: StaticString = #filePath, line: UInt = #line) {
        guard let value else {
            return XCTFail("no video attribute", file: file, line: line)
        }
        XCTAssertTrue(value.isFinite && value >= 0.0 && value <= Double(Int32.max), "\(value)", file: file, line: line)
        _ = Int32(value)
    }

    func testSanitizedVideoDuration() {
        XCTAssertEqual(sanitizedVideoDuration(.nan), 0.0)
        XCTAssertEqual(sanitizedVideoDuration(.infinity), 0.0)
        XCTAssertEqual(sanitizedVideoDuration(-1.0), 0.0)
        XCTAssertEqual(sanitizedVideoDuration(1e20), Double(Int32.max))
        XCTAssertEqual(sanitizedVideoDuration(12.5), 12.5)
    }

    func testApiAttribute() {
        for value in self.badValues {
            let attributes = telegramMediaFileAttributesFromApiAttributes([.documentAttributeVideo(.init(flags: 0, duration: value, w: 1, h: 1, preloadPrefixSize: nil, videoStartTs: nil, videoCodec: nil))])
            assertConvertible(attributes.first.flatMap(self.duration))
        }
        let attributes = telegramMediaFileAttributesFromApiAttributes([.documentAttributeVideo(.init(flags: 0, duration: 12.5, w: 1, h: 1, preloadPrefixSize: nil, videoStartTs: nil, videoCodec: nil))])
        XCTAssertEqual(attributes.first.flatMap(self.duration), 12.5)
    }

    func testStoredAttribute() throws {
        for value in self.badValues {
            let encoder = PostboxEncoder()
            self.video(value).encode(encoder)
            assertConvertible(self.duration(TelegramMediaFileAttribute(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))))

            var builder = FlatBufferBuilder(initialSize: 256)
            let offset = self.video(value).encodeToFlatBuffers(builder: &builder)
            builder.finish(offset: offset)
            assertConvertible(self.duration(try TelegramMediaFileAttribute(flatBuffersData: builder.data)))
        }
    }
}
