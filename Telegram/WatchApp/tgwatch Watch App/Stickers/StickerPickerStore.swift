import Foundation
import Observation
import OSLog
@preconcurrency import TDShim

enum PickerLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

@Observable
@MainActor
final class StickerPickerStore {
    private(set) var favorites: [PickerSticker] = []
    private(set) var recents: [PickerSticker] = []
    private(set) var sets: [PickerSet] = []
    private(set) var loadState: PickerLoadState = .loading

    private let loader: StickerPickerLoader
    private let logger = Logger(watchCategory: "stickerpicker")
    private var files: [Int: File] = [:]
    /// Visible cells per file id. One sticker can be on screen in several cells (Favorites,
    /// Frequently Used, a set cover), so a download is cancelled only when the last one goes.
    @ObservationIgnored private var visibleCells: [Int: Int] = [:]
    private var setStickers: [Int64: [PickerSticker]] = [:]

    init(loader: StickerPickerLoader) {
        self.loader = loader
    }

    /// Consumes `updateFile` only — grid cells read `fileSnapshot` and decode
    /// once the local path lands. `@Observable` re-evaluates the reading views,
    /// so no reproject is needed.
    func handle(_ update: Update) {
        if case .updateFile(let upd) = update {
            files[upd.file.id] = upd.file
        }
    }

    func fileSnapshot(fileId: Int) -> File? { files[fileId] }

    func requestFileDownload(fileId: Int, priority: Int = 2) {
        let count = visibleCells[fileId, default: 0]
        visibleCells[fileId] = count + 1
        guard count == 0 else { return }
        logger.info("requestFileDownload fileId=\(fileId, privacy: .public) priority=\(priority, privacy: .public)")
        Task { [logger, loader] in
            do {
                _ = try await loader.downloadFile(fileId: fileId, priority: priority)
            } catch {
                logger.warning("sticker download fileId=\(fileId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelFileDownload(fileId: Int) {
        let remaining = max(0, visibleCells[fileId, default: 0] - 1)
        guard remaining == 0 else {
            visibleCells[fileId] = remaining
            return
        }
        visibleCells[fileId] = nil
        logger.info("cancelFileDownload fileId=\(fileId, privacy: .public)")
        Task { [logger, loader] in
            do {
                try await loader.cancelDownloadFile(fileId: fileId)
            } catch {
                logger.warning("cancelDownloadFile fileId=\(fileId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Fetches favorites, recents, and installed sets concurrently. Each source
    /// is independent — one failing source still renders the others. `.failed`
    /// only when all three fail. Re-runs on every sheet open (keeps recents/
    /// favorites fresh); when already `.loaded` it refreshes the arrays in place
    /// rather than flashing the spinner.
    func load() async {
        if case .loaded = loadState {} else { loadState = .loading }
        async let favsTask = loader.favoriteStickers()
        async let recsTask = loader.recentStickers()
        async let setsTask = loader.installedStickerSets()
        let favs = try? await favsTask
        let recs = try? await recsTask
        let setInfos = try? await setsTask
        favorites = (favs ?? []).map(pickerSticker(from:))
        recents = (recs ?? []).map(pickerSticker(from:))
        sets = (setInfos ?? []).map(pickerSet(from:))
        if favs == nil, recs == nil, setInfos == nil {
            loadState = .failed("Couldn't load stickers")
        } else {
            loadState = .loaded
        }
    }

    /// Loads (and memoizes) a set's stickers for the detail grid.
    func loadSet(id: TdInt64) async -> [PickerSticker] {
        if let cached = setStickers[id.rawValue] { return cached }
        do {
            let projected = try await loader.stickerSet(id: id).map(pickerSticker(from:))
            setStickers[id.rawValue] = projected
            return projected
        } catch {
            logger.warning("loadSet id=\(id.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
