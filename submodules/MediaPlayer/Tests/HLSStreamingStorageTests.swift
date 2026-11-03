import Foundation
import XCTest
import CoreMedia
import SwiftSignalKit
import Postbox
import DiskWriteAccounting
@testable import UniversalMediaPlayer

/// The HLS player writes each streamed byte once (into its MediaBox resource) and a cached segment not at all
/// (see HLSStreamingStorage). Writes are measured with DiskWriteAccounting, which every writer on these paths reports to.
final class HLSStreamingStorageTests: XCTestCase {
    private final class TestResource: MediaResource {
        let id: MediaResourceId
        let size: Int64?

        init(_ id: String, size: Int64) {
            self.id = MediaResourceId(id)
            self.size = size
        }

        var streamable: Bool {
            return true
        }

        var headerSize: Int32 {
            return 0
        }

        func isEqual(to: MediaResource) -> Bool {
            return (to as? TestResource)?.id == self.id
        }
    }

    private static let tempBoxInitialized: Bool = {
        TempBox.initializeShared(basePath: NSTemporaryDirectory() + "HLSStreamingStorageTests-TempBox", processType: "tests", launchSpecificId: Int64(Date().timeIntervalSince1970 * 1000))
        return true
    }()

    // h264_bframes_cmaf.mp4: ftyp + moov (initialization segment), then one moof + mdat fragment.
    private static let initializationRange: Range<Int64> = 0 ..< 672
    private static let segmentRange: Range<Int64> = 672 ..< 16177

    private var basePath: String!
    private var mediaBox: MediaBox!
    private var fileData: Data!
    private var fetchedBytes = Atomic<Int>(value: 0)

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCTAssertTrue(HLSStreamingStorageTests.tempBoxInitialized)
        self.basePath = NSTemporaryDirectory() + "HLSStreamingStorageTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
        self.mediaBox = MediaBox(basePath: self.basePath, isMainProcess: false)
        self.fileData = try Data(contentsOf: URL(fileURLWithPath: MediaTestSupport.resourcePath("h264_bframes_cmaf", "mp4")))
        XCTAssertEqual(self.fileData.count, Int(HLSStreamingStorageTests.segmentRange.upperBound))

        let fileData = self.fileData!
        let fetchedBytes = self.fetchedBytes
        // The network: serves any asked range in 4 KB parts.
        self.mediaBox.fetchResource = { _, ranges, _ in
            return ranges
            |> castError(MediaResourceDataFetchError.self)
            |> take(1)
            |> mapToSignal { ranges -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> in
                return Signal { subscriber in
                    for (range, _) in ranges {
                        var offset = Int(range.lowerBound)
                        while offset < min(Int(range.upperBound), fileData.count) {
                            let end = min(offset + 4096, fileData.count)
                            let _ = fetchedBytes.modify { $0 + (end - offset) }
                            subscriber.putNext(.dataPart(resourceOffset: Int64(offset), data: fileData.subdata(in: offset ..< end), range: 0 ..< Int64(end - offset), complete: end == fileData.count))
                            offset = end
                        }
                    }
                    return EmptyDisposable
                }
            }
        }
    }

    override func tearDown() {
        self.mediaBox.dataQueue.sync {}
        for storageBox in [self.mediaBox.storageBox, self.mediaBox.cacheStorageBox] {
            let semaphore = DispatchSemaphore(value: 0)
            let disposable = storageBox.get(ids: []).start(completed: {
                semaphore.signal()
            })
            let _ = semaphore.wait(timeout: .now() + 10.0)
            disposable.dispose()
        }
        self.mediaBox = nil
        let _ = try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    private var resource: TestResource {
        return TestResource("hls-quality-720", size: Int64(self.fileData.count))
    }

    private var parameters: MediaResourceFetchParameters {
        return MediaResourceFetchParameters(tag: nil, info: nil, location: nil, contentType: 2, isRandomAccessAllowed: true)
    }

    /// Data bytes written since `snapshot`: everything except the few bytes of file maps.
    private func dataBytesWritten(since snapshot: DiskWriteSnapshot) -> Int64 {
        let delta = DiskWriteAccounting.shared.snapshot().subtracting(snapshot)
        return delta.totalBytes - (delta.bytes[DiskWriteCategory.mediaBoxMap] ?? 0)
    }

    private func segment(_ range: Range<Int64>) throws -> Data {
        var result: Data?
        let done = self.expectation(description: "segment")
        let disposable = HLSStreamingStorage.segmentData(mediaBox: self.mediaBox, resource: self.resource, resourceSize: Int64(self.fileData.count), range: range, parameters: self.parameters).start(next: { data in
            result = data
            done.fulfill()
        })
        self.wait(for: [done], timeout: 10.0)
        disposable.dispose()
        self.mediaBox.dataQueue.sync {}
        // TempBox disposal and MediaBox stores are queued.
        self.mediaBox.dataQueue.sync {}
        return try XCTUnwrap(result)
    }

    // MARK: - Serving segments to hls.js

    func testAStreamedSegmentIsWrittenOnce() throws {
        let before = DiskWriteAccounting.shared.snapshot()
        let data = try self.segment(HLSStreamingStorageTests.segmentRange)
        XCTAssertEqual(data, self.fileData.subdata(in: Int(HLSStreamingStorageTests.segmentRange.lowerBound) ..< Int(HLSStreamingStorageTests.segmentRange.upperBound)))
        XCTAssertEqual(self.dataBytesWritten(since: before), Int64(data.count))
        XCTAssertTrue(self.mediaBox.internal_resourceDataIsCached(id: self.resource.id, size: Int64(self.fileData.count), in: HLSStreamingStorageTests.segmentRange))
    }

    func testACachedSegmentIsServedWithoutWritingOrFetching() throws {
        let _ = try self.segment(HLSStreamingStorageTests.segmentRange)
        let fetchedAfterFirst = self.fetchedBytes.with { $0 }

        let before = DiskWriteAccounting.shared.snapshot()
        let data = try self.segment(HLSStreamingStorageTests.segmentRange)
        XCTAssertEqual(data.count, Int(HLSStreamingStorageTests.segmentRange.upperBound - HLSStreamingStorageTests.segmentRange.lowerBound))
        XCTAssertEqual(self.dataBytesWritten(since: before), 0)
        XCTAssertEqual(self.fetchedBytes.with { $0 }, fetchedAfterFirst)
    }

    // MARK: - Appended segments for the chunk player

    func testAnAppendedSegmentServedFromTheCacheIsPlayedFromItWithoutWriting() throws {
        let served = HLSServedSegments()
        let initialization = try self.segment(HLSStreamingStorageTests.initializationRange)
        let segment = try self.segment(HLSStreamingStorageTests.segmentRange)
        served.noteServed(mediaBox: self.mediaBox, resource: self.resource, resourceSize: Int64(self.fileData.count), range: HLSStreamingStorageTests.initializationRange, data: initialization)
        served.noteServed(mediaBox: self.mediaBox, resource: self.resource, resourceSize: Int64(self.fileData.count), range: HLSStreamingStorageTests.segmentRange, data: segment)

        let before = DiskWriteAccounting.shared.snapshot()
        let content = try XCTUnwrap(HLSStreamingStorage.partContent(initializationData: Data(initialization), segmentData: Data(segment), codecName: "h264", servedSegments: served))
        XCTAssertEqual(self.dataBytesWritten(since: before), 0)

        guard case let .mediaBoxRanges(ranges) = content else {
            return XCTFail("expected a part read from MediaBox, got \(content)")
        }
        XCTAssertEqual(ranges.ranges, [HLSStreamingStorageTests.initializationRange, HLSStreamingStorageTests.segmentRange])
        XCTAssertTrue(ranges.ignoreAudioEditList)

        // The chunk player decodes the same frames as from the file itself.
        let copy = TempBox.shared.tempFile(fileName: "copy.mp4")
        try self.fileData.write(to: URL(fileURLWithPath: copy.path))
        let fromFile = self.readVideoTimestamps(.tempFile(ChunkMediaPlayerPart.TempFile(file: copy)))
        TempBox.shared.dispose(copy)
        let fromMediaBox = self.readVideoTimestamps(.mediaBoxRanges(ranges))
        XCTAssertFalse(fromFile.isEmpty)
        XCTAssertEqual(fromMediaBox, fromFile)
    }

    func testAnAppendedSegmentThatDiffersFromWhatWasServedGoesThroughATempFile() throws {
        let served = HLSServedSegments()
        let initialization = try self.segment(HLSStreamingStorageTests.initializationRange)
        let segment = try self.segment(HLSStreamingStorageTests.segmentRange)
        served.noteServed(mediaBox: self.mediaBox, resource: self.resource, resourceSize: Int64(self.fileData.count), range: HLSStreamingStorageTests.initializationRange, data: initialization)
        served.noteServed(mediaBox: self.mediaBox, resource: self.resource, resourceSize: Int64(self.fileData.count), range: HLSStreamingStorageTests.segmentRange, data: segment)

        // Same length and edges as the served segment, one byte changed in the middle.
        var changed = segment
        changed[changed.count / 2] ^= 0xff

        let before = DiskWriteAccounting.shared.snapshot()
        let content = try XCTUnwrap(HLSStreamingStorage.partContent(initializationData: initialization, segmentData: changed, codecName: "h264", servedSegments: served))
        guard case let .tempFile(tempFile) = content else {
            return XCTFail("expected a temporary file, got \(content)")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: tempFile.file.path)), initialization + changed)
        XCTAssertEqual(self.dataBytesWritten(since: before), Int64(initialization.count + changed.count))
    }

    func testTheProbeReadsTheAppendedBytesFromMemory() throws {
        let probe = try XCTUnwrap(extractFFMpegMediaInfo(data: self.fileData))
        let filePath = try MediaTestSupport.resourcePath("h264_bframes_cmaf", "mp4")
        let fromFile = try XCTUnwrap(extractFFMpegMediaInfo(path: filePath))
        XCTAssertEqual(probe.video?.codecName, "h264")
        XCTAssertEqual(probe.video?.startTime, fromFile.video?.startTime)
        XCTAssertEqual(probe.video?.duration, fromFile.video?.duration)
        XCTAssertGreaterThan(probe.video?.duration.seconds ?? 0.0, 0.0)

        let initializationOnly = try XCTUnwrap(extractFFMpegMediaInfo(data: self.fileData.prefix(Int(HLSStreamingStorageTests.initializationRange.upperBound))))
        XCTAssertEqual(initializationOnly.video?.duration.value, 0)
    }

    private func readVideoTimestamps(_ content: FFMpegMediaDataReaderV2.Content) -> [CMTime] {
        let reader = FFMpegMediaDataReaderV2(content: content, isVideo: true, codecName: "h264", ignoreEditList: true)
        var result: [CMTime] = []
        loop: for _ in 0 ..< 1000 {
            switch reader.readSampleBuffer() {
            case let .frame(sampleBuffer):
                result.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            case .endOfStream, .error:
                break loop
            case .waitingForMoreData:
                break loop
            }
        }
        return result
    }
}
