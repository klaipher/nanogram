import Foundation
import FFMpegBinding

enum FFMpegSoftwareDecodeThreads {
    static let minimumPixelCount = 1280 * 720
    static let maximumThreadCount = 8

    static func threadCount(codecId: Int32, width: Int32, height: Int32, processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int32 {
        guard codecId == FFMpegCodecIdAV1, Int(width) * Int(height) >= minimumPixelCount else {
            return 1
        }
        return Int32(max(1, min(processorCount, maximumThreadCount)))
    }

    static func apply(to codecContext: FFMpegAVCodecContext, codecId: Int32, width: Int32, height: Int32, processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        let count = threadCount(codecId: codecId, width: width, height: height, processorCount: processorCount)
        if count != codecContext.threadCount() {
            codecContext.setThreadCount(count)
        }
    }
}
