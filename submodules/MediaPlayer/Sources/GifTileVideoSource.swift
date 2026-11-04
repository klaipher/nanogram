import Foundation
import CoreMedia

public final class GifTileVideoSource {
    public let source: SoftwareVideoSource
    public let hardwareSlot: HardwareDecoderSlot?
    public let isPassthrough: Bool

    public init(path: String, hintVP9: Bool, width: Int?, height: Int?, usesHardwareDecoding: Bool, budget: HardwareDecoderBudget = GifTileHardwareDecoding.budget) {
        var slot: HardwareDecoderSlot?
        var skipLoopFilter = false
        if usesHardwareDecoding {
            let options = GifTileHardwareDecoding.decoderOptions(width: width, height: height, hintVP9: hintVP9, budget: budget)
            slot = options.slot
            skipLoopFilter = options.skipLoopFilter
        }
        let decodingSource = SoftwareVideoSource(path: path, hintVP9: hintVP9, unpremultiplyAlpha: true, useHardwareAcceleration: slot != nil, skipLoopFilter: skipLoopFilter, reusePixelBuffers: true)
        if decodingSource.hasStream || hintVP9 {
            self.source = decodingSource
            self.hardwareSlot = decodingSource.hasStream ? slot : nil
            self.isPassthrough = false
            return
        }
        slot = nil
        let passthroughSource = SoftwareVideoSource(path: path, hintVP9: false, unpremultiplyAlpha: true, passthroughDecoder: true)
        self.hardwareSlot = nil
        if passthroughSource.hasStream {
            self.source = passthroughSource
            self.isPassthrough = true
        } else {
            self.source = decodingSource
            self.isPassthrough = false
        }
    }
}

public enum GifTileFrameSchedule {
    public static func framesToEnqueue(_ frames: [MediaTrackFrame], baseTimestamp: Double, timestamp: Double) -> (enqueue: [MediaTrackFrame], consumedCount: Int) {
        var latestFrameIndex: Int?
        for index in 0 ..< frames.count {
            if baseTimestamp + frames[index].position.seconds + frames[index].duration.seconds <= timestamp {
                latestFrameIndex = index
            }
        }
        guard let latestFrameIndex else {
            return ([], 0)
        }
        let latestFrame = frames[latestFrameIndex]
        if latestFrame.decoded {
            return ([latestFrame], latestFrameIndex + 1)
        }
        return (Array(frames[0 ... latestFrameIndex]), latestFrameIndex + 1)
    }
}
