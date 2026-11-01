import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

private actor RecordingPickerLoader: StickerPickerLoader {
    private(set) var downloads: [Int] = []
    private(set) var cancels: [Int] = []

    func favoriteStickers() async throws -> [Sticker] { [] }
    func recentStickers() async throws -> [Sticker] { [] }
    func installedStickerSets() async throws -> [StickerSetInfo] { [] }
    nonisolated func stickerSet(id: TdInt64) async throws -> [Sticker] { [] }
    func downloadFile(fileId: Int, priority: Int) async throws -> File {
        downloads.append(fileId)
        throw CancellationError()
    }
    func cancelDownloadFile(fileId: Int) async throws { cancels.append(fileId) }
}

/// The same sticker can be on screen in two picker cells at once (in Favorites and in
/// Frequently Used, or a set's cover). A cell scrolling away cancelled the download the
/// other, still visible cell was waiting for, leaving it on the gray placeholder.
@MainActor
final class UIStickerPickerDownloadTests: XCTestCase {
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testCancelWaitsForTheLastVisibleCell() async {
        let loader = RecordingPickerLoader()
        let store = StickerPickerStore(loader: loader)

        store.requestFileDownload(fileId: 7)
        store.requestFileDownload(fileId: 7)
        await settle()
        let downloads = await loader.downloads
        XCTAssertEqual(downloads, [7], "one download for both cells")

        store.cancelFileDownload(fileId: 7)
        await settle()
        let cancelsAfterFirst = await loader.cancels
        XCTAssertEqual(cancelsAfterFirst, [], "the other cell still shows this sticker")

        store.cancelFileDownload(fileId: 7)
        await settle()
        let cancelsAfterSecond = await loader.cancels
        XCTAssertEqual(cancelsAfterSecond, [7])
    }

    func testSingleCellRequestAndCancel() async {
        let loader = RecordingPickerLoader()
        let store = StickerPickerStore(loader: loader)
        store.requestFileDownload(fileId: 3)
        store.cancelFileDownload(fileId: 3)
        await settle()
        let downloads = await loader.downloads
        let cancels = await loader.cancels
        XCTAssertEqual(downloads, [3])
        XCTAssertEqual(cancels, [3])

        // Visible again: downloads again.
        store.requestFileDownload(fileId: 3)
        await settle()
        let again = await loader.downloads
        XCTAssertEqual(again, [3, 3])
    }

    func testStrayCancelStillReachesTDLib() async {
        // A cancel with no matching request keeps the old behaviour (TDLib ignores it).
        let loader = RecordingPickerLoader()
        let store = StickerPickerStore(loader: loader)
        store.cancelFileDownload(fileId: 9)
        await settle()
        let cancels = await loader.cancels
        XCTAssertEqual(cancels, [9])
    }
}
