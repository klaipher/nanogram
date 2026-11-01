import XCTest
@testable import tgwatch_Watch_App

/// Where a full-screen video player starts. The round-video player only looked at the
/// path captured when the bubble was tapped, and its Retry button only asked TDLib for
/// the file again: for a file that is already downloaded TDLib sends no further
/// `updateFile`, so Retry after a playback failure (and an open whose download finished
/// after the tap) stayed on "0%" forever.
final class MediaPlayerStartTests: XCTestCase {
    private let exists: (String) -> Bool = { $0.hasPrefix("/ok") }

    func testPlaysTheTappedPathWhenItIsOnDisk() {
        XCTAssertEqual(playableVideoPath(visualPath: "/ok/a.mp4", snapshotPath: nil, fileExists: exists), "/ok/a.mp4")
    }

    func testFallsBackToTheStoresFinishedDownload() {
        XCTAssertEqual(playableVideoPath(visualPath: nil, snapshotPath: "/ok/b.mp4", fileExists: exists), "/ok/b.mp4")
        XCTAssertEqual(playableVideoPath(visualPath: "/gone/a.mp4", snapshotPath: "/ok/b.mp4", fileExists: exists), "/ok/b.mp4")
    }

    func testDownloadsWhenNothingIsOnDisk() {
        XCTAssertNil(playableVideoPath(visualPath: nil, snapshotPath: nil, fileExists: exists))
        XCTAssertNil(playableVideoPath(visualPath: "/gone/a.mp4", snapshotPath: "/gone/b.mp4", fileExists: exists))
        XCTAssertNil(playableVideoPath(visualPath: "", snapshotPath: "", fileExists: { _ in true }))
    }
}
