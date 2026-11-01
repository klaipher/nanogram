import XCTest
import Postbox
import FlatBuffers
import FlatSerialization
@testable import TelegramCore

/// Byte vectors (thumbnails, file references, waveforms, callback data) stored in FlatBuffers
/// must come back byte for byte, and empty or missing ones as nil.
final class FlatBuffersByteVectorTests: XCTestCase {
    private func randomData(_ count: Int) -> Data {
        var data = Data(count: count)
        for i in 0 ..< count {
            data[i] = UInt8.random(in: 0 ... 255)
        }
        return data
    }

    private let sizes = [0, 1, 2, 15, 16, 17, 255, 1500, 70_000]

    private func makeFile(thumbnail: Data?, fileReference: Data?, waveform: Data?) -> TelegramMediaFile {
        let resource = CloudDocumentMediaResource(datacenterId: 2, fileId: 77, accessHash: 88, size: 1000, fileReference: fileReference, fileName: "a.ogg")
        let previewResource = CloudPhotoSizeMediaResource(datacenterId: 2, photoId: 5, accessHash: 6, sizeSpec: "m", size: nil, fileReference: fileReference)
        let preview = TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 10, height: 10), resource: previewResource, progressiveSizes: [], immediateThumbnailData: thumbnail)
        return TelegramMediaFile(
            fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 77),
            partialReference: nil,
            resource: resource,
            previewRepresentations: [preview],
            videoThumbnails: [],
            immediateThumbnailData: thumbnail,
            mimeType: "audio/ogg",
            size: 1000,
            attributes: [.Audio(isVoice: true, duration: 3, title: nil, performer: nil, waveform: waveform)],
            alternativeRepresentations: []
        )
    }

    private func flatBuffersData(_ file: TelegramMediaFile) -> Data {
        var builder = FlatBufferBuilder(initialSize: 1024)
        let offset = file.encodeToFlatBuffers(builder: &builder)
        builder.finish(offset: offset)
        return builder.data
    }

    private func accessor(_ data: Data) -> TelegramMediaFile.Accessor {
        var byteBuffer = ByteBuffer(data: data)
        let object: TelegramCore_TelegramMediaFile = FlatBuffers_getRoot(byteBuffer: &byteBuffer)
        return TelegramMediaFile.Accessor(object, data)
    }

    private func expected(_ data: Data) -> Data? {
        return data.isEmpty ? nil : data
    }

    func testMediaFileByteVectorsRoundTrip() throws {
        for size in self.sizes {
            let bytes = self.randomData(size)
            let file = self.makeFile(thumbnail: bytes, fileReference: bytes, waveform: bytes)
            let data = self.flatBuffersData(file)

            let accessor = self.accessor(data)
            XCTAssertEqual(accessor.immediateThumbnailData, self.expected(bytes), "size \(size)")

            var byteBuffer = ByteBuffer(data: data)
            let object: TelegramCore_TelegramMediaFile = FlatBuffers_getRoot(byteBuffer: &byteBuffer)
            let decoded = try TelegramMediaFile(flatBuffersObject: object)
            XCTAssertEqual(decoded.immediateThumbnailData, self.expected(bytes), "size \(size)")
            XCTAssertEqual(decoded.previewRepresentations.first?.immediateThumbnailData, self.expected(bytes))
            XCTAssertEqual((decoded.resource as? CloudDocumentMediaResource)?.fileReference, self.expected(bytes))
            XCTAssertEqual((decoded.previewRepresentations.first?.resource as? CloudPhotoSizeMediaResource)?.fileReference, self.expected(bytes))
            if case let .Audio(_, _, _, _, waveform) = decoded.attributes.first {
                XCTAssertEqual(waveform, self.expected(bytes), "size \(size)")
            } else {
                XCTFail("no audio attribute")
            }
        }
    }

    func testMissingVectorsDecodeAsNil() throws {
        let file = self.makeFile(thumbnail: nil, fileReference: nil, waveform: nil)
        let data = self.flatBuffersData(file)
        XCTAssertNil(self.accessor(data).immediateThumbnailData)
        var byteBuffer = ByteBuffer(data: data)
        let object: TelegramCore_TelegramMediaFile = FlatBuffers_getRoot(byteBuffer: &byteBuffer)
        let decoded = try TelegramMediaFile(flatBuffersObject: object)
        XCTAssertNil(decoded.immediateThumbnailData)
        XCTAssertNil((decoded.resource as? CloudDocumentMediaResource)?.fileReference)
    }

    func testImageByteVectorsRoundTrip() throws {
        for size in self.sizes {
            let bytes = self.randomData(size)
            let representation = TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 1, height: 1), resource: CloudPhotoSizeMediaResource(datacenterId: 1, photoId: 2, accessHash: 3, sizeSpec: "s", size: nil, fileReference: bytes), progressiveSizes: [], immediateThumbnailData: bytes)
            let image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 2), representations: [representation], immediateThumbnailData: bytes, reference: .cloud(imageId: 2, accessHash: 3, fileReference: bytes), partialReference: nil, flags: [])
            var builder = FlatBufferBuilder(initialSize: 1024)
            let offset = image.encodeToFlatBuffers(builder: &builder)
            builder.finish(offset: offset)
            var byteBuffer = ByteBuffer(data: builder.data)
            let object: TelegramCore_TelegramMediaImage = FlatBuffers_getRoot(byteBuffer: &byteBuffer)
            let decoded = try TelegramMediaImage(flatBuffersObject: object)
            XCTAssertEqual(decoded.immediateThumbnailData, self.expected(bytes), "size \(size)")
            XCTAssertEqual(decoded.representations.first?.immediateThumbnailData, self.expected(bytes))
            if case let .cloud(_, _, fileReference) = decoded.reference {
                XCTAssertEqual(fileReference, self.expected(bytes))
            } else {
                XCTFail("no reference")
            }
        }
    }

    func testInstantPageCallbackDataRoundTrip() throws {
        for size in self.sizes {
            let bytes = self.randomData(size)
            let button = InstantPageButton(text: .plain("Go"), action: .callback(requiresPassword: false, data: MemoryBuffer(data: bytes)), color: nil, isLink: false)
            var builder = FlatBufferBuilder(initialSize: 1024)
            let offset = button.encodeToFlatBuffers(builder: &builder)
            builder.finish(offset: offset)
            var byteBuffer = ByteBuffer(data: builder.data)
            let object: TelegramCore_InstantPageButton = FlatBuffers_getRoot(byteBuffer: &byteBuffer)
            let decoded = try InstantPageButton(flatBuffersObject: object)
            if case let .callback(_, data) = decoded.action {
                XCTAssertEqual(data.makeData(), bytes, "size \(size)")
            } else {
                XCTFail("no callback action")
            }
        }
    }

    func testBulkCopyMatchesElementwiseCopyForEveryStorage() {
        for size in self.sizes {
            let bytes = self.randomData(size)
            let data = self.flatBuffersData(self.makeFile(thumbnail: bytes, fileReference: nil, waveform: nil))
            var buffers = [ByteBuffer(data: data), ByteBuffer(bytes: [UInt8](data))]
            for i in 0 ..< buffers.count {
                let object: TelegramCore_TelegramMediaFile = FlatBuffers_getRoot(byteBuffer: &buffers[i])
                XCTAssertEqual(object.immediateThumbnailData.makeData(), Data(object.immediateThumbnailData), "size \(size), storage \(i)")
                XCTAssertEqual(object.immediateThumbnailData.makeData(), bytes)
            }
        }
    }

    /// The emoji and sticker panels read every item's thumbnail through the accessor.
    func testThumbnailAccessorBenchmark() {
        let data = self.flatBuffersData(self.makeFile(thumbnail: self.randomData(1500), fileReference: nil, waveform: nil))
        let accessor = self.accessor(data)
        let iterations = 2000
        var total = 0
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0 ..< iterations {
            total += accessor.immediateThumbnailData?.count ?? 0
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        XCTAssertEqual(total, 1500 * iterations)
        print("FlatBuffers benchmark: \(iterations) reads of a 1500-byte thumbnail: \(String(format: "%.2f", ms)) ms")
    }
}
