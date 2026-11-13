import XCTest
@testable import BackgroundDiagnostics

final class PdfInlineViewingPolicyTests: XCTestCase {
    private let gigabyte: UInt64 = 1024 * 1024 * 1024

    func testSmallDocumentWithPlentyOfHeadroomStaysInline() {
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: 1, fileSize: 200 * 1024, headroom: 4 * gigabyte), .inline)
    }

    func testLowHeadroomSendsEvenOnePageReceiptToQuickLook() {
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: 1, fileSize: 200 * 1024, headroom: gigabyte), .quickLook)
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: 1, fileSize: 200 * 1024, headroom: PdfInlineViewingPolicy.minimumHeadroom - 1), .quickLook)
    }

    func testHeadroomAtTheLimitStaysInline() {
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: 1, fileSize: 1024, headroom: PdfInlineViewingPolicy.minimumHeadroom), .inline)
    }

    func testUnknownHeadroomDoesNotBlockInline() {
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: 3, fileSize: 1024, headroom: nil), .inline)
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: nil, fileSize: nil, headroom: nil), .inline)
    }

    func testLargeFileGoesToQuickLookEvenWithHeadroom() {
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: 10, fileSize: PdfInlineViewingPolicy.largeFileSize, headroom: 4 * gigabyte), .quickLook)
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: 10, fileSize: PdfInlineViewingPolicy.largeFileSize - 1, headroom: 4 * gigabyte), .inline)
    }

    func testManyPagesGoToQuickLook() {
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: PdfInlineViewingPolicy.largePageCount, fileSize: 1024, headroom: 4 * gigabyte), .quickLook)
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: PdfInlineViewingPolicy.largePageCount - 1, fileSize: 1024, headroom: 4 * gigabyte), .inline)
    }

    func testDetailLineShowsHeadroomWhenKnown() {
        let withHeadroom = MemoryDetailReport(memory: nil, threads: nil, zones: [], caches: [], instances: [], headroom: 2 * gigabyte)
        XCTAssertTrue(withHeadroom.logLine.contains("headroom 2048.0 MB"))
        let without = MemoryDetailReport(memory: nil, threads: nil, zones: [], caches: [], instances: [])
        XCTAssertFalse(without.logLine.contains("headroom"))
    }

    func testSmallBudgetLowersTheThreshold() {
        let budget = 2 * gigabyte
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: 1, fileSize: 1024, headroom: gigabyte, budget: budget), .inline)
        XCTAssertEqual(PdfInlineViewingPolicy.route(pageCount: 1, fileSize: 1024, headroom: gigabyte / 4, budget: budget), .quickLook)
    }

    func testLargeBudgetKeepsTheFullThreshold() {
        XCTAssertEqual(PdfInlineViewingPolicy.minimumHeadroom(budget: 10 * gigabyte), PdfInlineViewingPolicy.minimumHeadroom)
        XCTAssertEqual(PdfInlineViewingPolicy.minimumHeadroom(budget: nil), PdfInlineViewingPolicy.minimumHeadroom)
    }
}
