import Foundation
import FFMpegBinding
import SwiftSignalKit

enum FFMpegSoftwareDecodeThreads {
    static let minimumPixelCount = 1280 * 720
    static let maximumThreadCount = 8
    static let iOSMaximumThreadCount = 4

    static func threadCount(codecId: Int32, width: Int32, height: Int32, processorCount: Int = ProcessInfo.processInfo.activeProcessorCount, maximumThreadCount: Int = FFMpegSoftwareDecodeThreads.maximumThreadCount) -> Int32 {
        guard codecId == FFMpegCodecIdAV1, Int(width) * Int(height) >= minimumPixelCount else {
            return 1
        }
        return Int32(max(1, min(processorCount, maximumThreadCount)))
    }

    /// iOS: at most four threads and never more than the performance cores (the caller passes their count), one while Low Power Mode is on or the device is hot.
    static func iOSThreadCount(codecId: Int32, width: Int32, height: Int32, processorCount: Int = ProcessInfo.processInfo.activeProcessorCount, isLowPowerModeEnabled: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> Int32 {
        if isLowPowerModeEnabled || thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return 1
        }
        return threadCount(codecId: codecId, width: width, height: height, processorCount: processorCount, maximumThreadCount: iOSMaximumThreadCount)
    }

    static func performanceCoreCount() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, nil, 0) == 0, value > 0 else {
            return nil
        }
        return Int(value)
    }

    static func apply(to codecContext: FFMpegAVCodecContext, codecId: Int32, width: Int32, height: Int32, processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        #if os(macOS)
        let count = threadCount(codecId: codecId, width: width, height: height, processorCount: processorCount)
        #elseif os(iOS)
        // Experiment softwareDecodeThreads, off by default until the A/B on an A15/A16 device is done.
        guard ExperimentalPerformanceFlags.shared.isEnabled(.softwareDecodeThreads) else {
            return
        }
        let count = iOSThreadCount(codecId: codecId, width: width, height: height, processorCount: performanceCoreCount() ?? processorCount)
        #else
        let count: Int32 = 1
        #endif
        if count != codecContext.threadCount() {
            codecContext.setThreadCount(count)
        }
    }
}
