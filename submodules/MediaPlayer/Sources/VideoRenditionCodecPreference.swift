import Foundation

/// Which of two renditions of the same quality an HLS video plays. AV1 is the smaller file, but on a device without
/// a hardware AV1 decoder (everything before the A17 Pro) it is decoded in software, and the iPhone build of FFmpeg
/// decodes a stream on one thread: one core is pegged and the battery goes faster than with hardware H.264/HEVC. So
/// software AV1 is the last resort there: used only when the quality has no other rendition.
public enum VideoRenditionCodecPreference {
    public static func isAv1(_ codec: String?) -> Bool {
        return codec == "av1" || codec == "av01"
    }

    /// Whether `candidate` replaces `current`, the rendition kept so far for the same quality. Renditions of the
    /// same kind replace each other in order (the last one wins). With hardware AV1 an AV1 rendition, once kept,
    /// stays; without it AV1 never replaces another codec and any other codec replaces AV1.
    public static func shouldReplace(currentCodec: String?, candidateCodec: String?, isHardwareAv1Supported: Bool) -> Bool {
        let currentIsAv1 = self.isAv1(currentCodec)
        let candidateIsAv1 = self.isAv1(candidateCodec)
        if isHardwareAv1Supported {
            return !currentIsAv1
        }
        // Software only: AV1 never replaces another codec, and anything else replaces AV1.
        return !candidateIsAv1
    }

    /// Whether hardware AV1 is used: what the device reports (VideoToolbox), unless the app configuration's
    /// `ios_enable_hardware_av1` key is present and false, which switches it off. The key never enables what the device
    /// cannot decode; absent means the device decides.
    public static func isHardwareAv1Enabled(deviceSupportsHardwareAv1: Bool, configurationFlag: Bool?) -> Bool {
        if configurationFlag == false {
            return false
        }
        return deviceSupportsHardwareAv1
    }

    /// The configuration's value of the key as a flag: nil when it is absent (or not a number), so absent is not false.
    public static func hardwareAv1Flag(configurationValue: Any?) -> Bool? {
        guard let value = configurationValue as? Double else {
            return nil
        }
        return value != 0.0
    }
}
