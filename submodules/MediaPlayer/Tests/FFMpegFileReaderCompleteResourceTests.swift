import Foundation
import XCTest
import CoreMedia
import Postbox
@testable import TelegramMediaPlayer

final class FFMpegFileReaderCompleteResourceTests: XCTestCase {
    private final class TestResource: MediaResource {
        let id: MediaResourceId

        init(_ id: String) {
            self.id = MediaResourceId(id)
        }

        var size: Int64? {
            return nil
        }

        var streamable: Bool {
            return false
        }

        var headerSize: Int32 {
            return 0
        }

        func isEqual(to: MediaResource) -> Bool {
            return (to as? TestResource)?.id == self.id
        }
    }

    private static let tempBoxInitialized: Bool = {
        TempBox.initializeShared(basePath: NSTemporaryDirectory() + "FFMpegFileReaderCompleteResourceTests-TempBox", processType: "tests", launchSpecificId: Int64(Date().timeIntervalSince1970 * 1000))
        return true
    }()

    private var basePath: String!

    override func setUp() {
        super.setUp()
        XCTAssertTrue(FFMpegFileReaderCompleteResourceTests.tempBoxInitialized)
        self.basePath = NSTemporaryDirectory() + "FFMpegFileReaderCompleteResourceTests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
    }

    override func tearDown() {
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    private func openDescriptorCount(path: String) -> Int {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var count = 0
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in 0 ..< getdtablesize() {
            if fcntl(fd, F_GETPATH, &buffer) == 0 {
                let openPath = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
                if openPath == target {
                    count += 1
                }
            }
        }
        return count
    }

    private func decode(_ reader: FFMpegFileReader, afterFirstFrame: () -> Void = {}) -> [(pts: CMTime, bytes: Data)] {
        var frames: [(pts: CMTime, bytes: Data)] = []
        while frames.count < 400 {
            switch reader.readFrame(argb: false) {
            case let .frame(frame):
                var bytes = Data()
                if let imageBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {
                    bytes = MediaTestSupport.visibleBytes(imageBuffer)
                }
                frames.append((CMSampleBufferGetPresentationTimeStamp(frame.sampleBuffer), bytes))
                if frames.count == 1 {
                    afterFirstFrame()
                }
            case .endOfStream:
                return frames
            case .waitingForMoreData, .error:
                XCTFail("unexpected reader result")
                return frames
            }
        }
        return frames
    }

    private func makeReader(_ source: FFMpegFileReader.SourceDescription) throws -> FFMpegFileReader {
        return try XCTUnwrap(FFMpegFileReader(
            source: source,
            passthroughDecoder: false,
            useHardwareAcceleration: false,
            selectedStream: .mediaType(.video),
            seek: nil,
            maxReadablePts: nil,
            ignoreEditList: false
        ))
    }

    func testCompleteResourceIsReadThroughOneOpenFileAndDecodesLikeTheFile() throws {
        let fixture = try MediaTestSupport.resourcePath("h264_bframes", "mp4")
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let mediaBox = MediaBox(basePath: self.basePath, isMainProcess: false)
        let resource = TestResource("complete-resource")
        mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
        let completePath = try XCTUnwrap(mediaBox.completedResourcePath(id: resource.id))
        XCTAssertEqual(self.openDescriptorCount(path: completePath), 0)

        let expected = self.decode(try self.makeReader(.file(fixture)))
        XCTAssertGreaterThan(expected.count, 10)

        var openWhileDecoding = -1
        let reader = try self.makeReader(.resource(mediaBox: mediaBox, resource: resource, resourceSize: Int64(data.count), mappedRanges: [0 ..< Int64(data.count)]))
        let frames = self.decode(reader, afterFirstFrame: {
            openWhileDecoding = self.openDescriptorCount(path: completePath)
        })
        XCTAssertEqual(openWhileDecoding, 1)
        XCTAssertEqual(frames.count, expected.count)
        XCTAssertEqual(frames.map { $0.pts }, expected.map { $0.pts })
        XCTAssertTrue(zip(frames, expected).allSatisfy { $0.bytes == $1.bytes })
        withExtendedLifetime(reader) {}
    }
}
