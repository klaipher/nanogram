import Foundation
import SwiftSignalKit
import Postbox
import ManagedFile
import DiskWriteAccounting

/// Disk traffic of the HLS (hls.js) video player: what it reads and what it writes for each streamed segment.
///
/// Every byte of a streamed segment used to be written three times (MetricKit disk-write report of 2026-11-02, 35 of
/// 101 samples): fetched into a TempBox partial file through a private MediaBox file context, read back and copied
/// into the MediaBox resource, then written once more, after the initialization segment, to a TempBox `.mp4` for the
/// chunk player. A segment that was already cached was copied into a TempBox file before being served, and again
/// into the `.mp4`.
///
/// Now a segment is fetched straight into its MediaBox resource (the one write) and served from there, and the chunk
/// player reads the appended segment from the same MediaBox ranges (`ChunkMediaPlayerPart.MediaBoxRanges`). A cached
/// segment is served and played with no write at all. A temporary file is still written when the appended bytes
/// are not exactly bytes the server source handed out (hls.js changed them), or for hardware AV1, which plays through
/// AVFoundation from a file.
public enum HLSStreamingStorage {
    /// `range` of `resource`, from the media cache when it has it, otherwise fetched into the media cache first.
    public static func segmentData(mediaBox: MediaBox, resource: MediaResource, resourceSize: Int64, range: Range<Int64>, parameters: MediaResourceFetchParameters?) -> Signal<Data?, NoError> {
        return Signal { subscriber in
            let fetchDisposable = mediaBox.fetchedResourceData(resource, in: range, priority: .default, parameters: parameters).start()
            let dataDisposable = (mediaBox.resourceData(resource, size: resourceSize, in: range, mode: .complete)
            |> filter { _, isComplete in
                return isComplete
            }
            |> take(1)).start(next: { data, _ in
                subscriber.putNext(data)
                subscriber.putCompletion()
            })
            return ActionDisposable {
                fetchDisposable.dispose()
                dataDisposable.dispose()
            }
        }
    }

    /// What the chunk player plays for one appended media segment.
    public static func partContent(initializationData: Data?, segmentData: Data, codecName: String?, servedSegments: HLSServedSegments) -> ChunkMediaPlayerPart.Content? {
        let isHardwareAV1 = (codecName == "av1" || codecName == "av01") && internal_isHardwareAv1Supported
        if !isHardwareAV1, let segment = servedSegments.match(segmentData) {
            var ranges: [Range<Int64>] = []
            if let initializationData {
                if let initialization = servedSegments.match(initializationData), initialization.mediaBox === segment.mediaBox, initialization.resource.id == segment.resource.id {
                    ranges.append(initialization.range)
                } else {
                    return self.tempFilePartContent(initializationData: initializationData, segmentData: segmentData)
                }
            }
            ranges.append(segment.range)
            return .mediaBoxRanges(ChunkMediaPlayerPart.MediaBoxRanges(mediaBox: segment.mediaBox, resource: segment.resource, resourceSize: segment.resourceSize, ranges: ranges, ignoreAudioEditList: true))
        }
        return self.tempFilePartContent(initializationData: initializationData, segmentData: segmentData)
    }

    /// What the chunk player plays for one segment of the native HLS player, whose bytes (`initData`, then
    /// `segmentData`) were just read from `initRange` and `dataRange` of `resource` in the media cache. They are played
    /// in place from those ranges: no copy, no write. A temporary file is written only for hardware AV1, which
    /// AVFoundation reads from a path. That file comes from `tempFileCache`, so the same segment made into a part
    /// again is not written again. It is not deleted when the part is released: its owner gives it back with
    /// `releaseTempFile`.
    public static func nativePartContent(mediaBox: MediaBox, resource: MediaResource, resourceSize: Int64, initRange: Range<Int64>?, dataRange: Range<Int64>, initData: Data, segmentData: Data, codecName: String?, isHardwareAv1Supported: Bool = internal_isHardwareAv1Supported, tempFileCache: HLSTempFileCache = HLSTempFileCache.shared) -> ChunkMediaPlayerPart.Content? {
        let isHardwareAV1 = VideoRenditionCodecPreference.isAv1(codecName) && isHardwareAv1Supported
        if isHardwareAV1 {
            let key = HLSTempFileCache.Key(resourceId: resource.id.stringRepresentation, initRange: initRange, dataRange: dataRange)
            let file = tempFileCache.acquire(key: key, write: {
                return self.writeTempFile(initializationData: initRange == nil ? nil : initData, segmentData: segmentData)
            })
            guard let file else {
                return nil
            }
            return .tempFile(ChunkMediaPlayerPart.TempFile(file: file, ignoreAudioEditList: true, deletesFileOnRelease: false))
        }
        var ranges: [Range<Int64>] = []
        if let initRange {
            ranges.append(initRange)
        }
        ranges.append(dataRange)
        return .mediaBoxRanges(ChunkMediaPlayerPart.MediaBoxRanges(mediaBox: mediaBox, resource: resource, resourceSize: resourceSize, ranges: ranges, ignoreAudioEditList: true))
    }

    /// Gives back the file of a part made by `nativePartContent`: a cached file stays cached for the next part made
    /// from the same bytes, any other is disposed.
    public static func releaseTempFile(_ file: TempBoxFile, tempFileCache: HLSTempFileCache = HLSTempFileCache.shared) {
        if !tempFileCache.release(file) {
            TempBox.shared.dispose(file)
        }
    }

    private static func tempFilePartContent(initializationData: Data?, segmentData: Data, deletesFileOnRelease: Bool = true) -> ChunkMediaPlayerPart.Content? {
        guard let written = self.writeTempFile(initializationData: initializationData, segmentData: segmentData) else {
            return nil
        }
        return .tempFile(ChunkMediaPlayerPart.TempFile(file: written.file, ignoreAudioEditList: true, deletesFileOnRelease: deletesFileOnRelease))
    }

    private static func writeTempFile(initializationData: Data?, segmentData: Data) -> (file: TempBoxFile, bytes: Int)? {
        let tempFile = TempBox.shared.tempFile(fileName: "data.mp4")
        var combinedData = Data()
        if let initializationData {
            combinedData.append(initializationData)
        }
        combinedData.append(segmentData)
        guard let _ = try? combinedData.write(to: URL(fileURLWithPath: tempFile.path), options: .atomic) else {
            TempBox.shared.dispose(tempFile)
            return nil
        }
        DiskWriteAccounting.shared.add(DiskWriteCategory.tempBoxHLS, bytes: combinedData.count)
        return (tempFile, combinedData.count)
    }
}

/// The byte ranges the HLS server source recently handed to hls.js, so an appended segment can be traced back to the
/// MediaBox bytes it came from. A match is confirmed by comparing every byte with the cache, so a segment hls.js
/// rewrote, or a range the cache no longer holds, never matches.
public final class HLSServedSegments: @unchecked Sendable {
    public static let shared = HLSServedSegments()

    public struct Match {
        public let mediaBox: MediaBox
        public let resource: MediaResource
        public let resourceSize: Int64
        public let range: Range<Int64>
    }

    private final class Entry {
        weak var mediaBox: MediaBox?
        let resource: MediaResource
        let resourceSize: Int64
        let range: Range<Int64>
        let fingerprint: Fingerprint

        init(mediaBox: MediaBox, resource: MediaResource, resourceSize: Int64, range: Range<Int64>, fingerprint: Fingerprint) {
            self.mediaBox = mediaBox
            self.resource = resource
            self.resourceSize = resourceSize
            self.range = range
            self.fingerprint = fingerprint
        }
    }

    private struct Fingerprint: Equatable {
        let count: Int
        let head: Data
        let tail: Data

        init(_ data: Data) {
            self.count = data.count
            let edge = min(64, data.count)
            self.head = data.prefix(edge)
            self.tail = data.suffix(edge)
        }
    }

    /// hls.js keeps at most 60 s ahead and 30 s behind per player; this covers several players at once.
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [Entry] = []

    public init(capacity: Int = 128) {
        self.capacity = capacity
    }

    public func noteServed(mediaBox: MediaBox, resource: MediaResource, resourceSize: Int64, range: Range<Int64>, data: Data) {
        let entry = Entry(mediaBox: mediaBox, resource: resource, resourceSize: resourceSize, range: range, fingerprint: Fingerprint(data))
        self.lock.lock()
        self.entries.removeAll(where: { $0.mediaBox == nil || ($0.mediaBox === mediaBox && $0.resource.id == resource.id && $0.range == range) })
        self.entries.append(entry)
        if self.entries.count > self.capacity {
            self.entries.removeFirst(self.entries.count - self.capacity)
        }
        self.lock.unlock()
    }

    /// The served range holding exactly `data`, confirmed against the cache. Reads the cache; call it off the main
    /// thread.
    public func match(_ data: Data) -> Match? {
        if data.isEmpty {
            return nil
        }
        let fingerprint = Fingerprint(data)
        self.lock.lock()
        let candidates = self.entries.reversed().filter { $0.fingerprint == fingerprint }
        self.lock.unlock()

        for candidate in candidates {
            guard let mediaBox = candidate.mediaBox else {
                continue
            }
            if HLSServedSegments.cacheHolds(data, mediaBox: mediaBox, resource: candidate.resource, resourceSize: candidate.resourceSize, range: candidate.range) {
                return Match(mediaBox: mediaBox, resource: candidate.resource, resourceSize: candidate.resourceSize, range: candidate.range)
            }
        }
        return nil
    }

    private static func cacheHolds(_ data: Data, mediaBox: MediaBox, resource: MediaResource, resourceSize: Int64, range: Range<Int64>) -> Bool {
        guard let (file, length) = mediaBox.internal_resourceData(id: resource.id, size: resourceSize, in: range), length == data.count else {
            return false
        }
        let blockSize = 256 * 1024
        var buffer = Data(count: min(blockSize, length))
        var offset = 0
        while offset < length {
            let count = min(blockSize, length - offset)
            let read = buffer.withUnsafeMutableBytes { bytes -> Int in
                return file.read(bytes.baseAddress!, count)
            }
            if read != count {
                return false
            }
            let equal = buffer.withUnsafeBytes { bufferBytes -> Bool in
                return data.withUnsafeBytes { dataBytes -> Bool in
                    return memcmp(bufferBytes.baseAddress!, dataBytes.baseAddress!.advanced(by: offset), count) == 0
                }
            }
            if !equal {
                return false
            }
            offset += count
        }
        return true
    }
}
