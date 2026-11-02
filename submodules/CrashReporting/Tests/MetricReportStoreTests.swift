import XCTest
import CrashReporting

final class MetricReportStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("MetricReportStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.directory)
        super.tearDown()
    }

    private func json(_ value: Int) -> Data {
        return Data("{\"value\":\(value)}".utf8)
    }

    func testSameReportIsStoredOnce() throws {
        let store = MetricReportStore(directory: self.directory)
        XCTAssertTrue(try store.store(self.json(1), kind: .diagnostics, intervalEnd: Date(timeIntervalSince1970: 100)))
        // MetricKit delivers past diagnostics again at every launch.
        XCTAssertFalse(try store.store(self.json(1), kind: .diagnostics, intervalEnd: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(try store.store(self.json(2), kind: .metrics, intervalEnd: Date(timeIntervalSince1970: 200)))
        let reports = store.reports()
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports[0].name.hasPrefix("metrics-200-"))
        XCTAssertTrue(reports[1].name.hasPrefix("diagnostics-100-"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: reports[1].path)), self.json(1))
    }

    func testKeepsTheNewestWithinLimits() throws {
        let store = MetricReportStore(directory: self.directory, maxFiles: 3, maxBytes: 1_000_000)
        for value in 0 ..< 6 {
            try store.store(self.json(value), kind: .metrics, intervalEnd: Date(timeIntervalSince1970: Double(1000 + value)))
        }
        XCTAssertEqual(store.reports().map { $0.name.split(separator: "-")[1] }, ["1005", "1004", "1003"])

        let small = MetricReportStore(directory: self.directory.appendingPathComponent("small"), maxFiles: 10, maxBytes: 30)
        for value in 0 ..< 4 {
            try small.store(self.json(10 + value), kind: .metrics, intervalEnd: Date(timeIntervalSince1970: Double(value)))
        }
        // Each report is 12 bytes: two fit in 30 bytes; the newest is always kept.
        XCTAssertEqual(small.reports().count, 2)
    }

    func testEmptyStore() {
        XCTAssertTrue(MetricReportStore(directory: self.directory).reports().isEmpty)
    }
}
