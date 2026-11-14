import Foundation
@preconcurrency import TDShim

/// Decides which `updateFile` events change what the message rows show (WATCH-LIST-1).
///
/// A video download emits an update for every few KB, and each one rebuilt every row of the window. The rows only
/// depend on whether a file is downloaded, where it is, whether a download is active and its size, so progress-only
/// updates reproject once per 5% step instead. The store still keeps the newest `File` for views that read the
/// snapshot (the player's progress ring), and a flip to completed always gets through.
struct FileUpdateGate {
    /// Progress is compared in steps of 1/`steps` of the file.
    static let steps = 20

    private struct Key: Equatable {
        let completed: Bool
        let path: String
        let active: Bool
        let canBeDownloaded: Bool
        let size: Int64
        let expectedSize: Int64
        let uploadCompleted: Bool
        let downloadStep: Int
        let uploadStep: Int
    }

    private var seen: [Int: Key] = [:]

    /// True when the rows may look different after `file`'s update.
    mutating func shouldReproject(for file: File) -> Bool {
        let key = Self.key(for: file)
        if seen[file.id] == key { return false }
        seen[file.id] = key
        return true
    }

    mutating func forget(fileId: Int) {
        seen.removeValue(forKey: fileId)
    }

    private static func key(for file: File) -> Key {
        let total = max(file.expectedSize, file.size)
        return Key(
            completed: file.local.isDownloadingCompleted,
            path: file.local.path,
            active: file.local.isDownloadingActive,
            canBeDownloaded: file.local.canBeDownloaded,
            size: file.size,
            expectedSize: file.expectedSize,
            uploadCompleted: file.remote.isUploadingCompleted,
            downloadStep: step(file.local.downloadedSize, of: total),
            uploadStep: step(file.remote.uploadedSize, of: total)
        )
    }

    private static func step(_ part: Int64, of total: Int64) -> Int {
        guard total > 0, part > 0 else { return 0 }
        let fraction = Double(min(part, total)) / Double(total)
        return Int(fraction * Double(steps))
    }
}
