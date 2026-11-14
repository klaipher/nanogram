import Foundation

// Which decode path a video takes, as pure rules. The probes live in `MediaCapabilities`.
public enum VideoDecodePolicy {
    // Passthrough hands the compressed packets to the system decoder. AV1 has no software decoder in the
    // system, so on a chip without a hardware AV1 decoder the packets go to dav1d instead.
    public static func usesPassthrough(requested: Bool, isAv1: Bool, hardwareAv1: Bool) -> Bool {
        guard requested else {
            return false
        }
        return !isAv1 || hardwareAv1
    }

    // The VideoToolbox hwaccel of FFmpeg. Below the size threshold software decoding costs less than a session.
    // FFmpeg's native AV1 decoder only decodes through the hwaccel, so without hardware AV1 it is never picked.
    public static func usesHardwareAcceleration(requested: Bool, isAv1: Bool, hardwareAv1: Bool, longSide: Int, minimumLongSide: Int) -> Bool {
        guard requested, longSide >= minimumLongSide else {
            return false
        }
        return !isAv1 || hardwareAv1
    }

    public static func decodePathLine(codec: String, hardware: Bool) -> String {
        return "decode codec=\(codec) path=\(hardware ? "hardware" : "software")"
    }
}

// Remembers which (codec, path) pairs were already reported, so a log gets one line per pair and not one per video.
public final class DecodePathReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<String>()

    public init() {
    }

    // The line to log the first time a pair is seen, nil afterwards.
    public func firstReport(codec: String, hardware: Bool) -> String? {
        let line = VideoDecodePolicy.decodePathLine(codec: codec, hardware: hardware)
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.seen.insert(line).inserted ? line : nil
    }
}
