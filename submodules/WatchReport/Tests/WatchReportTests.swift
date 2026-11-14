import XCTest
@testable import WatchReport

final class WatchReportTests: XCTestCase {
    private func payload(logBytes: Int = 10) -> WatchReportPayload {
        let log = (0 ..< max(1, logBytes / 10)).map { "line \($0)\n" }.joined()
        return WatchReportPayload(created: Date(timeIntervalSince1970: 1_700_000_000), files: [
            WatchReportFile(name: "info.txt", text: "Watch OS 26"),
            WatchReportFile(name: "log.txt", text: log)
        ])
    }

    func testPayloadRoundTrips() {
        let original = self.payload()
        guard let data = original.encoded(), let decoded = WatchReportPayload.decode(data) else {
            XCTFail("no round trip")
            return
        }
        XCTAssertEqual(decoded, original)
    }

    func testReplyPayloadStaysUnderTheMessageCap() throws {
        let data = try XCTUnwrap(self.payload(logBytes: 2_000_000).encoded(maximumBytes: WatchReportMessage.maximumReplyBytes))
        XCTAssertLessThanOrEqual(data.count, 60 * 1024)
        XCTAssertLessThan(WatchReportMessage.maximumReplyBytes, WatchReportMessage.maximumBytes)
    }

    func testLargeLogIsCutFromTheFrontToFit() {
        guard let data = self.payload(logBytes: 2_000_000).encoded(maximumBytes: 50_000), let decoded = WatchReportPayload.decode(data) else {
            XCTFail("did not encode")
            return
        }
        XCTAssertLessThanOrEqual(data.count, 50_000)
        let log = decoded.files.first { $0.name == "log.txt" }?.text ?? ""
        XCTAssertTrue(log.hasPrefix("[earlier lines cut"))
        XCTAssertTrue(log.contains("line 199999"), "the newest lines are kept")
        XCTAssertEqual(decoded.files.first { $0.name == "info.txt" }?.text, "Watch OS 26")
    }

    func testUnknownVersionIsRejected() throws {
        var payload = self.payload()
        payload.version = 99
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertNil(WatchReportPayload.decode(try encoder.encode(payload)))
        XCTAssertNil(WatchReportPayload.decode(Data("not json".utf8)))
    }

    func testLiveReplyBeatsTheStoredCopyAndTheStoredCopyBeatsNothing() {
        let live = self.payload()
        var stored = self.payload()
        stored.created = Date(timeIntervalSince1970: 1_600_000_000)
        XCTAssertEqual(watchReportChoose(live: live, stored: stored), .live(live))
        XCTAssertEqual(watchReportChoose(live: nil, stored: stored), .stored(stored))
        XCTAssertEqual(watchReportChoose(live: nil, stored: nil), .none)
    }

    func testStatusLinesSayWhyThereIsNoWatchPart() {
        XCTAssertTrue(watchReportStatusLine(.none, link: .noPairedWatch).contains("no paired Apple Watch"))
        XCTAssertTrue(watchReportStatusLine(.none, link: .appNotInstalled).contains("not installed"))
        XCTAssertTrue(watchReportStatusLine(.none, link: .unreachableNoCopy).contains("not reachable"))
        XCTAssertTrue(watchReportStatusLine(.stored(self.payload()), link: .unreachable).contains("last copy"))
    }

    func testStoreKeepsTheNewestCopyAndRejectsGarbage() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("watch-report-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = WatchReportStore(directory: directory)
        XCTAssertNil(store.load())
        XCTAssertFalse(store.save(Data("junk".utf8)))
        var newer = self.payload()
        newer.created = Date(timeIntervalSince1970: 1_800_000_000)
        let older = self.payload()
        XCTAssertTrue(store.save(try XCTUnwrap(older.encoded())))
        XCTAssertTrue(store.save(try XCTUnwrap(newer.encoded())))
        XCTAssertFalse(store.save(try XCTUnwrap(older.encoded())))
        XCTAssertEqual(store.load(), newer)
    }
}
