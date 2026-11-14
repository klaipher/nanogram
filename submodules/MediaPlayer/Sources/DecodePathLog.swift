import Foundation
import TelegramCore
import MediaCapabilities

// One log line per (codec, hardware or software) pair per launch. Codec and path only, nothing about the video.
enum DecodePathLog {
    private static let reporter = DecodePathReporter()

    static func report(codecId: Int32, hardware: Bool) {
        guard let codec = resolveFFMpegCodecName(id: codecId), let line = self.reporter.firstReport(codec: codec, hardware: hardware) else {
            return
        }
        Logger.sharedIfInstalled?.log("MediaPlayer", line)
    }
}
