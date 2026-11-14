import XCTest
@testable import PhotoResources

final class MediaFileDataReadingTests: XCTestCase {
    private func makeTempFile(_ bytes: [UInt8]) throws -> String {
        let path = NSTemporaryDirectory() + "media-file-data-" + UUID().uuidString
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testCompleteAndIncompleteReadsReturnTheSameBytes() throws {
        let bytes = (0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let path = try makeTempFile(bytes)
        XCTAssertEqual(readMediaFileData(path: path, complete: true), Data(bytes))
        XCTAssertEqual(readMediaFileData(path: path, complete: false), Data(bytes))
    }

    func testEmptyFileReturnsEmptyData() throws {
        let path = try makeTempFile([])
        XCTAssertEqual(readMediaFileData(path: path, complete: true), Data())
    }

    func testMissingFileReturnsNil() {
        let path = NSTemporaryDirectory() + "missing-" + UUID().uuidString
        XCTAssertNil(readMediaFileData(path: path, complete: true))
        XCTAssertNil(readMediaFileData(path: path, complete: false))
    }
}
