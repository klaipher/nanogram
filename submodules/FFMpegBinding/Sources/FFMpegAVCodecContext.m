#import <FFMpegBinding/FFMpegAVCodecContext.h>

#import <FFMpegBinding/FFMpegAVFrame.h>
#import <FFMpegBinding/FFMpegAVCodec.h>

#import "libavformat/avformat.h"
#import "libavcodec/avcodec.h"
#import "libavutil/dict.h"

// VideoToolbox when FFmpeg offers it. When the hwaccel setup fails (no device, session limit, a
// profile VideoToolbox cannot decode), FFmpeg calls this again without it; then the software
// format, which FFmpeg puts last. Returning a format that is not in the list fails the decoder.
static enum AVPixelFormat getPreferredPixelFormat(__unused AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts) {
    enum AVPixelFormat last = AV_PIX_FMT_NONE;
    for (const enum AVPixelFormat *format = pix_fmts; *format != AV_PIX_FMT_NONE; format++) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) {
            return *format;
        }
        last = *format;
    }
    return last;
}

@interface FFMpegAVCodecContext () {
    FFMpegAVCodec *_codec;
    AVCodecContext *_impl;
    int32_t _opusDecoderComplexity;
    bool _opusBandwidthExtension;
}

@end

@implementation FFMpegAVCodecContext

- (instancetype)initWithCodec:(FFMpegAVCodec *)codec {
    self = [super init];
    if (self != nil) {
        _codec = codec;
        _impl = avcodec_alloc_context3((AVCodec *)[codec impl]);
        _impl->max_pixels = 4 * 1024 * 4 * 1024;
    }
    return self;
}

- (void)dealloc {
    if (_impl) {
        avcodec_free_context(&_impl);
    }
}

- (void *)impl {
    return _impl;
}

- (int32_t)channels {
    #if LIBAVFORMAT_VERSION_MAJOR >= 59
    return (int32_t)_impl->ch_layout.nb_channels;
    #else
    return (int32_t)_impl->channels;
    #endif
}

- (int32_t)sampleRate {
    return (int32_t)_impl->sample_rate;
}

- (FFMpegAVSampleFormat)sampleFormat {
    return (FFMpegAVSampleFormat)_impl->sample_fmt;
}

- (void)setOpusDecoderComplexity:(int32_t)complexity bandwidthExtension:(bool)bandwidthExtension {
    _opusDecoderComplexity = complexity;
    _opusBandwidthExtension = bandwidthExtension;
}

- (bool)open {
    AVCodec *codec = (AVCodec *)[_codec impl];
    AVDictionary *options = NULL;
    if (_opusDecoderComplexity > 0 && codec->id == AV_CODEC_ID_OPUS) {
        // Private options of the libopus decoder (klaipher/FFmpeg libopusdec.c): complexity 6/7 turns LACE/NoLACE on and
        // `osce_bwe` the bandwidth extension. avcodec_open2 consumes the entries it knows; a decoder without them ignores them.
        av_dict_set_int(&options, "osce_complexity", _opusDecoderComplexity, 0);
        if (_opusBandwidthExtension) {
            av_dict_set_int(&options, "osce_bwe", 1, 0);
        }
    }
    int result = avcodec_open2(_impl, codec, options != NULL ? &options : nil);
    av_dict_free(&options);
    return result >= 0;
}

- (bool)sendEnd {
    int status = avcodec_send_packet(_impl, nil);
    return status == 0;
}

- (void)setThreadCount:(int32_t)threadCount {
    _impl->thread_count = threadCount;
}

- (int32_t)threadCount {
    return (int32_t)_impl->thread_count;
}

- (void)setupHardwareAccelerationIfPossible {
    // Without a device FFmpeg's default get_format picks the software format.
    if (av_hwdevice_ctx_create(&_impl->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0) {
        _impl->get_format = getPreferredPixelFormat;
    }
}

- (void)setupHardwareAccelerationForcingSetupFailureForTesting {
    _impl->get_format = getPreferredPixelFormat;
}

- (void)setSkipLoopFilterToAll {
    _impl->skip_loop_filter = AVDISCARD_ALL;
}

- (void)setSkipNonReferenceFrames:(bool)skip {
    _impl->skip_frame = skip ? AVDISCARD_NONREF : AVDISCARD_DEFAULT;
}

- (FFMpegAVCodecContextReceiveResult)receiveIntoFrame:(FFMpegAVFrame *)frame {
    int status = avcodec_receive_frame(_impl, (AVFrame *)[frame impl]);
    if (status == 0) {
        return FFMpegAVCodecContextReceiveResultSuccess;
    } else if (status == -35) {
        return FFMpegAVCodecContextReceiveResultNotEnoughData;
    } else {
        return FFMpegAVCodecContextReceiveResultError;
    }
}

- (void)flushBuffers {
    avcodec_flush_buffers(_impl);
}

@end
