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
}
