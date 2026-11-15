import Foundation
import SwiftSignalKit
import Postbox
import ManagedFile
import DiskWriteAccounting

/// Disk traffic of the native HLS video player: what it writes for each streamed segment.
///
/// A segment is played in place from its MediaBox ranges (`ChunkMediaPlayerPart.MediaBoxRanges`): no copy and no
/// write. A temporary file is written only for hardware AV1, which plays through AVFoundation from a file.
public enum HLSStreamingStorage {
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
