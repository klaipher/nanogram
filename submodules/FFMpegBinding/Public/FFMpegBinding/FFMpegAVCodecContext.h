#import <Foundation/Foundation.h>

#import <FFMpegBinding/FFMpegAVSampleFormat.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, FFMpegAVCodecContextReceiveResult)
{
    FFMpegAVCodecContextReceiveResultError,
    FFMpegAVCodecContextReceiveResultNotEnoughData,
    FFMpegAVCodecContextReceiveResultSuccess,
};

@class FFMpegAVCodec;
@class FFMpegAVFrame;

@interface FFMpegAVCodecContext : NSObject

- (instancetype)initWithCodec:(FFMpegAVCodec *)codec;

- (void *)impl;
- (int32_t)channels;
- (int32_t)sampleRate;
- (FFMpegAVSampleFormat)sampleFormat;

// Opus speech enhancement (libopus 1.6 OSCE: LACE at complexity 6, NoLACE at 7, optional bandwidth extension of SILK-only
// wideband streams). Per context, so a caller opts in at each open: playback does, transcription and the notification
// extension never call it and keep the decoder default (complexity 0, output bit-identical to a libopus without OSCE).
// Applied by `open` through the libopus decoder options `osce_complexity` / `osce_bwe`, and only when the codec is Opus; a
// libopus built without OSCE ignores the complexity above 0 harmlessly. 0 turns it off. Must be called before `open`.
- (void)setOpusDecoderComplexity:(int32_t)complexity bandwidthExtension:(bool)bandwidthExtension;
- (bool)open;
- (bool)sendEnd;
- (void)setupHardwareAccelerationIfPossible;
// For tests: asks for the VideoToolbox format without a hardware device, so FFmpeg's hwaccel setup
// fails inside get_format and decoding has to continue in software. Must be called before `open`.
- (void)setupHardwareAccelerationForcingSetupFailureForTesting;
// Sets `skip_loop_filter = AVDISCARD_ALL`, disabling H.264/HEVC in-loop deblocking.
// Deblocked frames are also prediction references, so this drifts from the encoder's
// reconstruction until the next IDR, on top of the visible blocking. Only appropriate
// for small, short-looping thumbnails. Must be called before `open`.
- (void)setSkipLoopFilterToAll;
- (void)setThreadCount:(int32_t)threadCount;
- (int32_t)threadCount;
// Sets `skip_frame` to `AVDISCARD_NONREF` (or back to the default): packets of frames no other frame references are
// not decoded at all. Takes effect for the packets sent after it.
- (void)setSkipNonReferenceFrames:(bool)skip;
- (FFMpegAVCodecContextReceiveResult)receiveIntoFrame:(FFMpegAVFrame *)frame;
- (void)flushBuffers;

@end

NS_ASSUME_NONNULL_END
