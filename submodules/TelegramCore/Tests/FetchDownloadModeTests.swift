import XCTest
@testable import TelegramCore

final class FetchDownloadModeTests: XCTestCase {
    func testMtProtoKitDownloadsUseTheAdaptiveWindowAndLargerParts() {
        let mode = fetchDownloadMode(engineKind: .mtProtoKit)
        XCTAssertTrue(mode.fastDownloads)
        XCTAssertEqual(mode.masterPendingParts, 16)
        XCTAssertEqual(mode.cdnPendingParts, 32)
    }

    func testMtProtoKitDownloadsDoNotAskForCdnRedirects() {
        XCTAssertFalse(fetchDownloadMode(engineKind: .mtProtoKit).requestsCdn)
    }

    func testRustDownloadsAreUnchanged() {
        XCTAssertEqual(
            fetchDownloadMode(engineKind: .rust),
            FetchDownloadMode(fastDownloads: true, requestsCdn: true, masterPendingParts: 16, cdnPendingParts: 32)
        )
    }
}
