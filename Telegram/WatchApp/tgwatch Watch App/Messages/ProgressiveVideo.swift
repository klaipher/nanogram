import AVFoundation
import Foundation
import OSLog
@preconcurrency import TDShim

/// Starting video playback before the whole file has downloaded (WATCH-VIDEO-1).
///
/// TDLib downloads a file from offset 0 and reports `downloadedPrefixSize`, the number of bytes at the start of
/// the file that are on disk. An `AVAssetResourceLoaderDelegate` serves AVPlayer's byte-range requests from that
/// prefix and holds any request that reaches past it until more arrives, so a clip whose `moov` atom is at the front
/// starts after the first few hundred KB instead of the whole download. A clip with `moov` at the end makes
/// AVPlayer ask for the tail, which waits for the complete file: no faster than before, never slower.
/// Everything here sits behind `WatchFeature.progressiveVideoStart`; the full-download path is the fallback.
enum ProgressiveVideoPolicy {
    /// Bytes on disk, contiguous from 0, before a player is created: `ftyp` plus a front `moov` for a short clip.
    static let startPrefixBytes: Int64 = 256 * 1024
    /// Below this the plain download finishes about as fast as the player would start.
    static let minimumTotalBytes: Int64 = 1_024 * 1_024
    static let serveChunkBytes = 64 * 1_024
    /// Containers AVPlayer can read progressively through a resource loader.
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

/// Serves AVPlayer's reads of one growing TDLib file under the URL `nanogram-td://file/<id>`.
/// All state lives on `queue`, the delegate queue, so no locking is needed.
final class ProgressiveVideoLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "nanogram-td"
    let queue = DispatchQueue(label: "org.klaipher.Nanogram.watchkitapp.progressiveVideo")

    private let contentType: String
    private var path: String
    private var prefix: Int64
    private var total: Int64
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var invalidated = false
    private let logger = Logger(watchCategory: "progressivevideo")

    static func url(fileId: Int) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = "/\(fileId)"
        return components.url
    }

    init(file: File, mimeType: String) {
        contentType = ProgressiveVideoPolicy.contentType(forMimeType: mimeType)
        path = file.local.path
        prefix = ProgressiveVideoPolicy.availablePrefix(of: file)
        total = ProgressiveVideoPolicy.totalSize(of: file)
        super.init()
    }

    /// A newer snapshot of the file: more bytes, maybe a new path. Serves what the new prefix unblocks.
    func update(file: File) {
        queue.async { [self] in
            guard !invalidated else { return }
            if !file.local.path.isEmpty { path = file.local.path }
            prefix = max(prefix, ProgressiveVideoPolicy.availablePrefix(of: file))
            total = max(total, ProgressiveVideoPolicy.totalSize(of: file))
            servePending()
        }
    }

    /// The viewer went away: pending reads end with an error so AVPlayer lets go of them.
    func invalidate() {
        queue.async { [self] in
            invalidated = true
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            for request in pending { request.finishLoading(with: error) }
            pending.removeAll()
        }
    }

    // MARK: AVAssetResourceLoaderDelegate (called on `queue`)

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !invalidated else { return false }
        pending.append(loadingRequest)
        servePending()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
    }

    // MARK: Serving

    private func servePending() {
        pending.removeAll { serve($0) }
    }

    /// True when the request is done and can be dropped.
    private func serve(_ request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = total
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let requestedEnd = dataRequest.requestsAllDataToEndOfResource
            ? total
            : dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
        let end = total > 0 ? min(requestedEnd, total) : requestedEnd
        let outcome = ByteRangeServing.serve(
            sink: AVDataRequestSink(dataRequest),
            endOffset: end,
            prefix: prefix,
            read: { [path] offset, count in Self.read(path: path, offset: offset, count: count) }
        )
        if outcome == .finished {
            request.finishLoading()
            return true
        }
        return false
    }

    private static func read(path: String, offset: Int64, count: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }
}

private final class AVDataRequestSink: ByteRangeSink {
    private let request: AVAssetResourceLoadingDataRequest

    init(_ request: AVAssetResourceLoadingDataRequest) {
        self.request = request
    }

    var currentOffset: Int64 { request.currentOffset }

    func respond(with data: Data) {
        request.respond(with: data)
    }
}

/// One progressive playback: the resource loader, the asset behind it and the player item to play. Held by the
/// player view for as long as it plays (the asset keeps only a weak reference to its loader delegate).
@MainActor
final class ProgressiveVideoSession {
    private let loader: ProgressiveVideoLoader
    let item: AVPlayerItem

    init?(file: File, mimeType: String) {
        guard let url = ProgressiveVideoLoader.url(fileId: file.id) else { return nil }
        let loader = ProgressiveVideoLoader(file: file, mimeType: mimeType)
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        self.loader = loader
        self.item = AVPlayerItem(asset: asset)
    }

    func update(file: File) { loader.update(file: file) }
    func invalidate() { loader.invalidate() }
}
