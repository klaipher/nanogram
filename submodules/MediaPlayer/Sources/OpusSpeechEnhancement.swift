import Foundation
import SwiftSignalKit
import FFMpegBinding

/// The opt-in "Enhance voice messages" setting (Settings > Nanogram Features), as far as the media decoders are concerned.
///
/// libopus 1.6 can clean up the SILK layer of a voice message while it decodes (LACE at decoder complexity 6, NoLACE at 7)
/// and extend SILK-only wideband streams to full band. It is compiled into our libopus, and off unless a caller raises the
/// decoder complexity, which FFmpeg's libopus decoder takes as the private options `osce_complexity` and `osce_bwe`
/// (`FFMpegAVCodecContext.setOpusDecoderComplexity`).
///
/// The complexity is chosen per decoder open and only on PLAYBACK paths. The speech-to-text conversion
/// (`convertOpusToAAC`), the notification extension and everything else that opens an Opus decoder never call
/// `applyIfPlayback`, so they decode at complexity 0 as before: a 5 minute message through NoLACE would cost seconds of CPU
/// and would change what the recogniser hears. A change of the setting applies to the next decoder that is opened, that is,
/// the next message played.
public enum OpusSpeechEnhancement {
    /// libopus decoder complexity 7 selects NoLACE (6 would be LACE) and also lets bandwidth extension run.
    public static let playbackComplexity: Int32 = 7

    public struct DecoderOptions: Equatable {
        public let complexity: Int32
        public let bandwidthExtension: Bool

        public init(complexity: Int32, bandwidthExtension: Bool) {
            self.complexity = complexity
            self.bandwidthExtension = bandwidthExtension
        }
    }

    private static let enabledState = Atomic<Bool>(value: false)

    /// The switch, mirrored from `NanogramFeaturesSettings.voiceEnhancement` by the app (iOS `SharedAccountContext`, Mac
    /// `AppDelegate`). Read when a decoder is opened.
    public static var isEnabled: Bool {
        get {
            return enabledState.with { $0 }
        }
        set {
            let _ = enabledState.swap(newValue)
        }
    }

    /// The decoder options for one open: none (the stock decoder) unless the switch is on AND the open is for playback.
    public static func decoderOptions(enabled: Bool, isPlayback: Bool) -> DecoderOptions? {
        guard enabled, isPlayback else {
            return nil
        }
        return DecoderOptions(complexity: playbackComplexity, bandwidthExtension: true)
    }

    /// Call on a codec context of a playback path before `open()`. Does nothing for other codecs: the binding applies the
    /// options to Opus only.
    public static func applyIfPlayback(to codecContext: FFMpegAVCodecContext, isPlayback: Bool = true, enabled: Bool = OpusSpeechEnhancement.isEnabled) {
        if let options = decoderOptions(enabled: enabled, isPlayback: isPlayback) {
            codecContext.setOpusDecoderComplexity(options.complexity, bandwidthExtension: options.bandwidthExtension)
        }
    }
}
