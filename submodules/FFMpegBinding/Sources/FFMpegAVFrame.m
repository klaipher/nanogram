#import <FFMpegBinding/FFMpegAVFrame.h>

#import "libavformat/avformat.h"

@interface FFMpegAVFrame () {
    AVFrame *_impl;
}

@end

@implementation FFMpegAVFrame

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _impl = av_frame_alloc();
    }
    return self;
}

-(instancetype)initWithPixelFormat:(FFMpegAVFramePixelFormat)pixelFormat width:(int32_t)width height:(int32_t)height {
    self = [super init];
    if (self != nil) {
        _impl = av_frame_alloc();
        switch (pixelFormat) {
            case FFMpegAVFramePixelFormatYUV:
                _impl->format = AV_PIX_FMT_YUV420P;
                break;
            case FFMpegAVFramePixelFormatYUVA:
                _impl->format = AV_PIX_FMT_YUVA420P;
                break;
            case FFMpegAVFramePixelFormatYUV422:
            case FFMpegAVFramePixelFormatYUVA422:
            case FFMpegAVFramePixelFormatYUV444:
            case FFMpegAVFramePixelFormatYUVA444:
            case FFMpegAVFramePixelFormatYUV10:
            case FFMpegAVFramePixelFormatUnsupported:
                return nil;
        }
        _impl->width = width;
        _impl->height = height;
        
        av_frame_get_buffer(_impl, 0);
    }
    return self;
}

- (void)dealloc {
    if (_impl) {
        av_frame_free(&_impl);
    }
}

- (int32_t)width {
    return _impl->width;
}

- (int32_t)height {
    return _impl->height;
}

- (uint8_t **)data {
    return _impl->data;
}

- (int *)lineSize {
    return _impl->linesize;
}

- (int64_t)pts {
    return _impl->pts;
}

- (FFMpegAVFrameNativePixelFormat)nativePixelFormat {
    switch (_impl->format) {
        case AV_PIX_FMT_VIDEOTOOLBOX: {
            return FFMpegAVFrameNativePixelFormatVideoToolbox;
        }
        default: {
            return FFMpegAVFrameNativePixelFormatUnknown;
        }
    }
}

- (int64_t)duration {
#if LIBAVFORMAT_VERSION_MAJOR >= 59
    return _impl->duration;
#else
    return _impl->pkt_duration;
#endif
}

- (FFMpegAVFrameColorRange)colorRange {
    switch (_impl->color_range) {
        case AVCOL_RANGE_MPEG:
        case AVCOL_RANGE_UNSPECIFIED:
            return FFMpegAVFrameColorRangeRestricted;
        default:
            return FFMpegAVFrameColorRangeFull;
    }
}

- (void *)impl {
    return _impl;
}

- (void)copyColorRangeFrom:(FFMpegAVFrame *)other {
    AVFrame *source = (AVFrame *)[other impl];
    _impl->color_range = source->color_range;
    _impl->color_primaries = source->color_primaries;
    _impl->color_trc = source->color_trc;
    _impl->colorspace = source->colorspace;
}

- (int32_t)colorPrimaries {
    return (int32_t)_impl->color_primaries;
}

- (int32_t)colorTransfer {
    return (int32_t)_impl->color_trc;
}

- (int32_t)colorMatrix {
    return (int32_t)_impl->colorspace;
}

- (FFMpegAVFramePixelFormat)pixelFormat {
    switch (_impl->format) {
        case AV_PIX_FMT_YUVA420P:
            return FFMpegAVFramePixelFormatYUVA;
        case AV_PIX_FMT_YUV420P:
        case AV_PIX_FMT_YUVJ420P:
            return FFMpegAVFramePixelFormatYUV;
        case AV_PIX_FMT_YUV422P:
        case AV_PIX_FMT_YUVJ422P:
            return FFMpegAVFramePixelFormatYUV422;
        case AV_PIX_FMT_YUVA422P:
            return FFMpegAVFramePixelFormatYUVA422;
        case AV_PIX_FMT_YUV444P:
        case AV_PIX_FMT_YUVJ444P:
            return FFMpegAVFramePixelFormatYUV444;
        case AV_PIX_FMT_YUVA444P:
            return FFMpegAVFramePixelFormatYUVA444;
        case AV_PIX_FMT_YUV420P10LE:
            return FFMpegAVFramePixelFormatYUV10;
        default:
            return FFMpegAVFramePixelFormatUnsupported;
    }
}

@end
