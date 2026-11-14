import Foundation
import CoreMedia
import VideoToolbox

public enum MediaVideoCodec: String, CaseIterable, Sendable {
    case h264
    case hevc
    case hevcWithAlpha
    case vp9
    case av1
}

// What this device's hardware decodes and encodes. Each answer is probed once, on first use, and kept: the
// probes are cheap but sit on paths that run per video. Nothing in it is user data.
public final class MediaCapabilities: @unchecked Sendable {
    public static let shared = MediaCapabilities(decodeProbe: { codec in systemDecodeProbe(codec) }, encodeProbe: { systemEncodeProbe() })

    private let lock = NSLock()
    private let decodeProbe: @Sendable (MediaVideoCodec) -> Bool
    private let encodeProbe: @Sendable () -> Set<MediaVideoCodec>
    private var decode: [MediaVideoCodec: Bool] = [:]
    private var encode: Set<MediaVideoCodec>?

    init(decodeProbe: @escaping @Sendable (MediaVideoCodec) -> Bool, encodeProbe: @escaping @Sendable () -> Set<MediaVideoCodec>) {
        self.decodeProbe = decodeProbe
        self.encodeProbe = encodeProbe
    }

    // VP9 is asked only after the supplemental decoder was requested (iOS 26.2+); AV1 is true from the A17 Pro and
    // M3, so most of the supported fleet answers false and decodes AV1 with dav1d.
    public func isHardwareDecodeSupported(_ codec: MediaVideoCodec) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value = self.decode[codec] {
            return value
        }
        let value = self.decodeProbe(codec)
        self.decode[codec] = value
        return value
    }

    public func isHardwareEncodeSupported(_ codec: MediaVideoCodec) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value = self.encode {
            return value.contains(codec)
        }
        let value = self.encodeProbe()
        self.encode = value
        return value.contains(codec)
    }

    public static var isHardwareAv1Supported: Bool {
        return self.shared.isHardwareDecodeSupported(.av1)
    }

    // For the Send Logs block: lets reports from an A13, an A16 and an A17 Pro be told apart.
    public func reportLines() -> [String] {
        func flags(_ probe: (MediaVideoCodec) -> Bool) -> String {
            return MediaVideoCodec.allCases.map { "\($0.rawValue)=\(probe($0) ? "yes" : "no")" }.joined(separator: " ")
        }
        return [
            "Media capabilities",
            "hardware decode: " + flags({ self.isHardwareDecodeSupported($0) }),
            "hardware encode: " + flags({ self.isHardwareEncodeSupported($0) }),
        ]
    }
}

private func codecType(_ codec: MediaVideoCodec) -> CMVideoCodecType? {
    switch codec {
    case .h264:
        return kCMVideoCodecType_H264
    case .hevc:
        return kCMVideoCodecType_HEVC
    case .hevcWithAlpha:
        if #available(macOS 10.15, *) {
            return kCMVideoCodecType_HEVCWithAlpha
        }
        return nil
    case .vp9:
        if #available(iOS 26.2, macOS 11.0, *) {
            return kCMVideoCodecType_VP9
        }
        return nil
    case .av1:
        return kCMVideoCodecType_AV1
    }
}

private func systemDecodeProbe(_ codec: MediaVideoCodec) -> Bool {
    guard let type = codecType(codec) else {
        return false
    }
    if codec == .vp9 {
        // Before iOS 26.2 apps cannot opt in to the supplemental VP9 decoder.
        if #available(iOS 26.2, macOS 11.0, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(type)
        }
    }
    return VTIsHardwareDecodeSupported(type)
}

private func systemEncodeProbe() -> Set<MediaVideoCodec> {
    var list: CFArray?
    guard unsafe VTCopyVideoEncoderList(nil, &list) == noErr, let entries = list as? [[String: Any]] else {
        return []
    }
    var result = Set<MediaVideoCodec>()
    for codec in MediaVideoCodec.allCases {
        guard let type = codecType(codec) else {
            continue
        }
        let hardware = entries.contains { entry in
            guard let entryType = (entry[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value, entryType == type else {
                return false
            }
            return (entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue ?? false
        }
        if hardware {
            result.insert(codec)
        }
    }
    return result
}
