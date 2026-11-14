import Foundation
@preconcurrency import TDShim

/// Starting video playback before the whole file has downloaded (WATCH-VIDEO-1).
///
/// TDLib downloads a file from offset 0 and reports `downloadedPrefixSize`, the number of bytes at the start of
/// the file that are on disk.
///
/// BLOCKED: the player side needs `AVAssetResourceLoader`, which does not exist on watchOS (the first version
/// did not compile). Only the pure policy and byte-range serving logic remain; no player uses them, and every
/// video plays through the full-download path. A redesign (for example a local loopback HTTP server) is open.
enum ProgressiveVideoPolicy {
    /// Bytes on disk, contiguous from 0, before a player is created: `ftyp` plus a front `moov` for a short clip.
    static let startPrefixBytes: Int64 = 256 * 1024
    /// Below this the plain download finishes about as fast as the player would start.
    static let minimumTotalBytes: Int64 = 1_024 * 1_024
    static let serveChunkBytes = 64 * 1_024
    /// Containers a progressive player could read.
    static let supportedMimeTypes: Set<String> = ["video/mp4", "video/quicktime", "video/x-m4v"]

    /// The bytes at the start of the file that can be read now.
    static func availablePrefix(of file: File) -> Int64 {
        if file.local.isDownloadingCompleted { return max(file.size, file.local.downloadedSize) }
        guard file.local.downloadOffset == 0 else { return 0 }
        return max(0, file.local.downloadedPrefixSize)
    }

    static func totalSize(of file: File) -> Int64 {
        max(file.size, file.expectedSize)
    }

    /// True when a progressive player should be created for `file` now.
    static func shouldStart(file: File, mimeType: String) -> Bool {
        guard !file.local.isDownloadingCompleted, !file.local.path.isEmpty,
              supportedMimeTypes.contains(mimeType.lowercased()) else { return false }
        let total = totalSize(of: file)
        guard total >= minimumTotalBytes else { return false }
        let prefix = availablePrefix(of: file)
        return prefix >= startPrefixBytes && prefix < total
    }

    static func contentType(forMimeType mimeType: String) -> String {
        mimeType.lowercased() == "video/quicktime" ? "com.apple.quicktime-movie" : "public.mpeg-4"
    }

    enum RangePlan: Equatable {
        /// Respond with this many bytes from `currentOffset`.
        case serve(count: Int)
        /// The next bytes have not arrived yet.
        case wait
        /// The whole requested range has been answered.
        case finished
    }

    static func plan(currentOffset: Int64, endOffset: Int64, prefix: Int64, chunk: Int = serveChunkBytes) -> RangePlan {
        if currentOffset >= endOffset { return .finished }
        let available = prefix - currentOffset
        if available <= 0 { return .wait }
        return .serve(count: Int(min(Int64(chunk), available, endOffset - currentOffset)))
    }
}

/// What a data request needs: where it stands and a way to answer it. `AVAssetResourceLoadingDataRequest` is wrapped
/// so the serving logic is testable without AVFoundation objects.
protocol ByteRangeSink: AnyObject {
    var currentOffset: Int64 { get }
    func respond(with data: Data)
}

enum ByteRangeServing {
    enum Outcome: Equatable {
        case finished
        case waiting
    }

    /// Answers as much of `[currentOffset, endOffset)` as the prefix allows. `read(offset, count)` returns the file
    /// bytes, or nil when the file cannot be read right now (it moved when the download completed): the request
    /// then stays pending and is retried on the next update.
    static func serve(
        sink: ByteRangeSink,
        endOffset: Int64,
        prefix: Int64,
        read: (_ offset: Int64, _ count: Int) -> Data?
    ) -> Outcome {
        while true {
            switch ProgressiveVideoPolicy.plan(currentOffset: sink.currentOffset, endOffset: endOffset, prefix: prefix) {
            case .finished:
                return .finished
            case .wait:
                return .waiting
            case .serve(let count):
                guard let data = read(sink.currentOffset, count), !data.isEmpty else { return .waiting }
                sink.respond(with: data)
            }
        }
    }
}
