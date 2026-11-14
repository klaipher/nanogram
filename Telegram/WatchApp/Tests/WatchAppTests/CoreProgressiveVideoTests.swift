import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// WATCH-VIDEO-1: when a progressive player may start and how its reads are answered from a growing file.
final class CoreProgressiveVideoTests: XCTestCase {
    private func file(
        id: Int = 9, size: Int64 = 0, expected: Int64 = 5_000_000, path: String = "/tmp/v.mp4",
        prefix: Int64, downloaded: Int64? = nil, offset: Int64 = 0, completed: Bool = false
    ) throws -> File {
        let json = """
        {"@type":"file","id":\(id),"size":\(size),"expected_size":\(expected),
         "local":{"@type":"localFile","path":"\(path)","can_be_downloaded":true,"can_be_deleted":false,
                  "is_downloading_active":\(!completed),"is_downloading_completed":\(completed),
                  "download_offset":\(offset),"downloaded_prefix_size":\(prefix),"downloaded_size":\(downloaded ?? prefix)},
         "remote":{"@type":"remoteFile","id":"","unique_id":"","is_uploading_active":false,
                   "is_uploading_completed":true,"uploaded_size":0}}
        """
        return try CoreFixtures.tdlibDecoder().decode(File.self, from: Data(json.utf8))
    }

    // MARK: policy

    func testFlagShipsOff() {
        XCTAssertFalse(WatchFeature.progressiveVideoStart.defaultValue)
    }

    func testStartsOnceEnoughOfAnMP4IsOnDisk() throws {
        let start = ProgressiveVideoPolicy.startPrefixBytes
        XCTAssertFalse(ProgressiveVideoPolicy.shouldStart(file: try file(prefix: start - 1), mimeType: "video/mp4"))
        XCTAssertTrue(ProgressiveVideoPolicy.shouldStart(file: try file(prefix: start), mimeType: "video/mp4"))
        XCTAssertTrue(ProgressiveVideoPolicy.shouldStart(file: try file(prefix: start), mimeType: "VIDEO/MP4"))
        XCTAssertTrue(ProgressiveVideoPolicy.shouldStart(file: try file(prefix: start), mimeType: "video/quicktime"))
    }

    func testOtherContainersWaitForTheFullFile() throws {
        let f = try file(prefix: 600_000)
        XCTAssertFalse(ProgressiveVideoPolicy.shouldStart(file: f, mimeType: "video/webm"))
        XCTAssertFalse(ProgressiveVideoPolicy.shouldStart(file: f, mimeType: "video/x-matroska"))
        XCTAssertFalse(ProgressiveVideoPolicy.shouldStart(file: f, mimeType: ""))
    }

    func testSmallFilesAndFinishedDownloadsUseTheNormalPath() throws {
        XCTAssertFalse(ProgressiveVideoPolicy.shouldStart(
            file: try file(expected: 800_000, prefix: 400_000), mimeType: "video/mp4"), "finishes about as fast")
        XCTAssertFalse(ProgressiveVideoPolicy.shouldStart(
            file: try file(size: 5_000_000, prefix: 5_000_000, completed: true), mimeType: "video/mp4"))
    }

    func testNoPathYetOrAnOffsetDownloadDoesNotStart() throws {
        XCTAssertFalse(ProgressiveVideoPolicy.shouldStart(file: try file(path: "", prefix: 600_000), mimeType: "video/mp4"))
        XCTAssertFalse(ProgressiveVideoPolicy.shouldStart(file: try file(prefix: 600_000, offset: 1_000_000), mimeType: "video/mp4"),
                       "the prefix counts from the download offset, not from byte 0")
    }

    func testAvailablePrefix() throws {
        XCTAssertEqual(ProgressiveVideoPolicy.availablePrefix(of: try file(prefix: 300, downloaded: 900)), 300)
        XCTAssertEqual(ProgressiveVideoPolicy.availablePrefix(of: try file(prefix: 300, offset: 5)), 0)
        XCTAssertEqual(ProgressiveVideoPolicy.availablePrefix(of: try file(size: 1_000, prefix: 0, downloaded: 1_000, completed: true)), 1_000)
    }

    func testTotalSizeUsesTheKnownSize() throws {
        XCTAssertEqual(ProgressiveVideoPolicy.totalSize(of: try file(size: 0, expected: 700, prefix: 0)), 700)
        XCTAssertEqual(ProgressiveVideoPolicy.totalSize(of: try file(size: 900, expected: 700, prefix: 0)), 900)
    }

    func testContentTypes() {
        XCTAssertEqual(ProgressiveVideoPolicy.contentType(forMimeType: "video/mp4"), "public.mpeg-4")
        XCTAssertEqual(ProgressiveVideoPolicy.contentType(forMimeType: "video/quicktime"), "com.apple.quicktime-movie")
    }

    // MARK: range plan

    func testPlan() {
        typealias P = ProgressiveVideoPolicy
        XCTAssertEqual(P.plan(currentOffset: 0, endOffset: 0, prefix: 100), .finished)
        XCTAssertEqual(P.plan(currentOffset: 100, endOffset: 200, prefix: 100), .wait)
        XCTAssertEqual(P.plan(currentOffset: 0, endOffset: 1_000, prefix: 100, chunk: 64), .serve(count: 64))
        XCTAssertEqual(P.plan(currentOffset: 64, endOffset: 1_000, prefix: 100, chunk: 64), .serve(count: 36))
        XCTAssertEqual(P.plan(currentOffset: 0, endOffset: 30, prefix: 100, chunk: 64), .serve(count: 30))
    }

    // MARK: serving

    private final class FakeSink: ByteRangeSink {
        var currentOffset: Int64
        private(set) var received = Data()
        init(from offset: Int64) { currentOffset = offset }
        func respond(with data: Data) {
            received.append(data)
            currentOffset += Int64(data.count)
        }
    }

    private func source(count: Int) -> Data { Data((0..<count).map { UInt8($0 % 251) }) }

    private func reader(of data: Data) -> (Int64, Int) -> Data? {
        { offset, count in
            let start = Int(offset)
            guard start < data.count else { return nil }
            return data.subdata(in: start..<min(data.count, start + count))
        }
    }

    func testServesTheAvailablePrefixThenWaits() {
        let bytes = source(count: 300_000)
        let sink = FakeSink(from: 0)
        let outcome = ByteRangeServing.serve(sink: sink, endOffset: 300_000, prefix: 100_000, read: reader(of: bytes))
        XCTAssertEqual(outcome, .waiting)
        XCTAssertEqual(sink.received, bytes.prefix(100_000))
        XCTAssertEqual(sink.currentOffset, 100_000)
    }

    func testResumesFromWhereItStoppedWhenMoreArrives() {
        let bytes = source(count: 200_000)
        let sink = FakeSink(from: 0)
        _ = ByteRangeServing.serve(sink: sink, endOffset: 200_000, prefix: 70_000, read: reader(of: bytes))
        let outcome = ByteRangeServing.serve(sink: sink, endOffset: 200_000, prefix: 200_000, read: reader(of: bytes))
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(sink.received, bytes)
    }

    func testARangeInsideThePrefixFinishesAtOnce() {
        let bytes = source(count: 200_000)
        let sink = FakeSink(from: 1_000)
        let outcome = ByteRangeServing.serve(sink: sink, endOffset: 3_000, prefix: 100_000, read: reader(of: bytes))
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(sink.received, bytes.subdata(in: 1_000..<3_000))
    }

    func testARangeBeyondThePrefixServesNothingAndWaits() {
        let bytes = source(count: 200_000)
        let sink = FakeSink(from: 150_000)
        let outcome = ByteRangeServing.serve(sink: sink, endOffset: 160_000, prefix: 100_000, read: reader(of: bytes))
        XCTAssertEqual(outcome, .waiting)
        XCTAssertTrue(sink.received.isEmpty)
    }

    func testAnUnreadableFileLeavesTheRequestPending() {
        let sink = FakeSink(from: 0)
        let outcome = ByteRangeServing.serve(sink: sink, endOffset: 100, prefix: 100, read: { _, _ in nil })
        XCTAssertEqual(outcome, .waiting, "retried on the next update, e.g. after the file moved")
        XCTAssertTrue(sink.received.isEmpty)
    }

    func testServesFromARealFileOnDisk() throws {
        let bytes = source(count: 10_000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("progressive-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handleRead: (Int64, Int) -> Data? = { offset, count in
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(offset))
            return try? handle.read(upToCount: count)
        }
        let sink = FakeSink(from: 100)
        let outcome = ByteRangeServing.serve(sink: sink, endOffset: 9_000, prefix: 10_000, read: handleRead)
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(sink.received, bytes.subdata(in: 100..<9_000))
    }
}
