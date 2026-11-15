#import <FFMpegBinding/FFMpegAVFormatContext.h>

#import <FFMpegBinding/FFMpegAVIOContext.h>
#import <FFMpegBinding/FFMpegPacket.h>
#import <FFMpegBinding/FFMpegAVCodecContext.h>

#import "libavcodec/avcodec.h"
#import "libavformat/avformat.h"
#import "libavutil/display.h"
#import "libavutil/mem.h"

const int FFMpegCodecIdH264 = AV_CODEC_ID_H264;
const int FFMpegCodecIdHEVC = AV_CODEC_ID_HEVC;
const int FFMpegCodecIdMPEG4 = AV_CODEC_ID_MPEG4;
const int FFMpegCodecIdVP9 = AV_CODEC_ID_VP9;
const int FFMpegCodecIdVP8 = AV_CODEC_ID_VP8;
const int FFMpegCodecIdAV1 = AV_CODEC_ID_AV1;

static int get_stream_rotation(const AVStream *stream) {
    AVDictionaryEntry *e = av_dict_get (stream->metadata, "rotate", NULL, 0);
    if (e && e->value) {
        if (!strcmp (e->value, "90") || !strcmp (e->value, "-270")) {
            return 90;
        } else if (!strcmp (e->value, "270") || !strcmp (e->value, "-90")) {
            return 270;
        } else if (!strcmp (e->value, "180") || !strcmp (e->value, "-180")) {
            return 180;
        } else if (!strcmp (e->value, "0")) {
            return 0;
        }
    }
    
    const AVPacketSideData *displaymatrix = av_packet_side_data_get(stream->codecpar->coded_side_data, stream->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (displaymatrix) {
        return ((int)-av_display_rotation_get((int32_t *)displaymatrix->data) + 360) % 360;
    }
    
    return 0;
}

typedef struct FFMpegBitReader {
    const uint8_t *data;
    size_t size;
    size_t bitOffset;
} FFMpegBitReader;

static bool ffmpegBitReaderReadBit(FFMpegBitReader *reader, uint32_t *outBit) {
    if (reader->bitOffset >= reader->size * 8) {
        return false;
    }
    *outBit = (reader->data[reader->bitOffset / 8] >> (7 - (reader->bitOffset % 8))) & 1;
    reader->bitOffset += 1;
    return true;
}

static bool ffmpegBitReaderReadBits(FFMpegBitReader *reader, int count, uint32_t *outValue) {
    uint32_t value = 0;
    for (int i = 0; i < count; i++) {
        uint32_t bit = 0;
        if (!ffmpegBitReaderReadBit(reader, &bit)) {
            return false;
        }
        value = (value << 1) | bit;
    }
    *outValue = value;
    return true;
}

// Exp-Golomb ue(v). Values that need more than 31 bits are rejected.
static bool ffmpegBitReaderReadUE(FFMpegBitReader *reader, uint32_t *outValue) {
    int leadingZeros = 0;
    while (true) {
        uint32_t bit = 0;
        if (!ffmpegBitReaderReadBit(reader, &bit)) {
            return false;
        }
        if (bit) {
            break;
        }
        leadingZeros += 1;
        if (leadingZeros > 31) {
            return false;
        }
    }
    uint32_t suffix = 0;
    if (!ffmpegBitReaderReadBits(reader, leadingZeros, &suffix)) {
        return false;
    }
    *outValue = (uint32_t)(((uint64_t)1 << leadingZeros) - 1 + suffix);
    return true;
}

static bool ffmpegSkipScalingList(FFMpegBitReader *reader, int size) {
    int lastScale = 8;
    int nextScale = 8;
    for (int j = 0; j < size; j++) {
        if (nextScale != 0) {
            uint32_t codeNum = 0;
            if (!ffmpegBitReaderReadUE(reader, &codeNum)) {
                return false;
            }
            // se(v) from ue(v); the spec bounds delta_scale to -128...127.
            int64_t delta = (codeNum & 1) ? ((int64_t)codeNum + 1) / 2 : -((int64_t)codeNum / 2);
            if (delta < -128 || delta > 127) {
                return false;
            }
            nextScale = (int)((lastScale + delta + 256) % 256);
        }
        lastScale = (nextScale == 0) ? lastScale : nextScale;
    }
    return true;
}

static bool ffmpegSkipHrdParameters(FFMpegBitReader *reader) {
    uint32_t cpbCountMinus1 = 0, unused = 0;
    if (!ffmpegBitReaderReadUE(reader, &cpbCountMinus1) || cpbCountMinus1 > 31) {
        return false;
    }
    if (!ffmpegBitReaderReadBits(reader, 8, &unused)) {
        return false;
    }
    for (uint32_t i = 0; i <= cpbCountMinus1; i++) {
        if (!ffmpegBitReaderReadUE(reader, &unused) || !ffmpegBitReaderReadUE(reader, &unused) || !ffmpegBitReaderReadBits(reader, 1, &unused)) {
            return false;
        }
    }
    return ffmpegBitReaderReadBits(reader, 20, &unused);
}

// Parses the first SPS of an avcC record far enough to tell whether the decoder can know the
// output delay without decoding: pic_order_cnt_type 2 (output order is decoding order) or a
// VUI bitstream_restriction (max_num_reorder_frames is signalled, and FFmpeg's decoder then
// uses it instead of guessing). Returns false for anything it cannot parse.
static bool ffmpegAvcCSignalsReorderDelay(const uint8_t *extradata, int extradataSize) {
    if (extradata == NULL || extradataSize < 8 || extradata[0] != 1) {
        return false;
    }
    if ((extradata[5] & 0x1f) == 0) {
        return false;
    }
    size_t spsLength = ((size_t)extradata[6] << 8) | (size_t)extradata[7];
    if (spsLength < 4 || 8 + spsLength > (size_t)extradataSize) {
        return false;
    }
    const uint8_t *nal = extradata + 8;
    if ((nal[0] & 0x1f) != 7) {
        return false;
    }
    // Drop the NAL header and the emulation prevention bytes.
    uint8_t rbsp[512];
    size_t rbspLength = 0;
    int zeroCount = 0;
    for (size_t i = 1; i < spsLength && rbspLength < sizeof(rbsp); i++) {
        uint8_t byte = nal[i];
        if (zeroCount >= 2 && byte == 3) {
            zeroCount = 0;
            continue;
        }
        rbsp[rbspLength++] = byte;
        zeroCount = (byte == 0) ? (zeroCount + 1) : 0;
    }
    FFMpegBitReader reader = { .data = rbsp, .size = rbspLength, .bitOffset = 0 };
    uint32_t profileIdc = 0, unused = 0, flag = 0;
    if (!ffmpegBitReaderReadBits(&reader, 8, &profileIdc) || !ffmpegBitReaderReadBits(&reader, 16, &unused) || !ffmpegBitReaderReadUE(&reader, &unused)) {
        return false;
    }
    switch (profileIdc) {
        case 100: case 110: case 122: case 244: case 44: case 83: case 86: case 118: case 128: case 138: case 139: case 134: case 135: {
            uint32_t chromaFormatIdc = 0;
            if (!ffmpegBitReaderReadUE(&reader, &chromaFormatIdc) || chromaFormatIdc > 3) {
                return false;
            }
            if (chromaFormatIdc == 3 && !ffmpegBitReaderReadBits(&reader, 1, &unused)) {
                return false;
            }
            if (!ffmpegBitReaderReadUE(&reader, &unused) || !ffmpegBitReaderReadUE(&reader, &unused) || !ffmpegBitReaderReadBits(&reader, 1, &unused) || !ffmpegBitReaderReadBits(&reader, 1, &flag)) {
                return false;
            }
            if (flag) {
                int listCount = (chromaFormatIdc != 3) ? 8 : 12;
                for (int i = 0; i < listCount; i++) {
                    uint32_t present = 0;
                    if (!ffmpegBitReaderReadBits(&reader, 1, &present)) {
                        return false;
                    }
                    if (present && !ffmpegSkipScalingList(&reader, i < 6 ? 16 : 64)) {
                        return false;
                    }
                }
            }
            break;
        }
        default:
            break;
    }
    uint32_t pocType = 0;
    if (!ffmpegBitReaderReadUE(&reader, &unused) || !ffmpegBitReaderReadUE(&reader, &pocType)) {
        return false;
    }
    if (pocType == 0) {
        if (!ffmpegBitReaderReadUE(&reader, &unused)) {
            return false;
        }
    } else if (pocType == 1) {
        uint32_t cycleLength = 0;
        if (!ffmpegBitReaderReadBits(&reader, 1, &unused) || !ffmpegBitReaderReadUE(&reader, &unused) || !ffmpegBitReaderReadUE(&reader, &unused) || !ffmpegBitReaderReadUE(&reader, &cycleLength) || cycleLength > 255) {
            return false;
        }
        for (uint32_t i = 0; i < cycleLength; i++) {
            if (!ffmpegBitReaderReadUE(&reader, &unused)) {
                return false;
            }
        }
    } else if (pocType != 2) {
        return false;
    }
    uint32_t frameMbsOnly = 0;
    // max_num_ref_frames, gaps flag, width, height, frame_mbs_only_flag
    if (!ffmpegBitReaderReadUE(&reader, &unused) || !ffmpegBitReaderReadBits(&reader, 1, &unused) || !ffmpegBitReaderReadUE(&reader, &unused) || !ffmpegBitReaderReadUE(&reader, &unused) || !ffmpegBitReaderReadBits(&reader, 1, &frameMbsOnly)) {
        return false;
    }
    if (!frameMbsOnly && !ffmpegBitReaderReadBits(&reader, 1, &unused)) {
        return false;
    }
    // direct_8x8_inference_flag, frame_cropping_flag
    if (!ffmpegBitReaderReadBits(&reader, 1, &unused) || !ffmpegBitReaderReadBits(&reader, 1, &flag)) {
        return false;
    }
    if (flag) {
        for (int i = 0; i < 4; i++) {
            if (!ffmpegBitReaderReadUE(&reader, &unused)) {
                return false;
            }
        }
    }
    uint32_t vuiPresent = 0;
    if (!ffmpegBitReaderReadBits(&reader, 1, &vuiPresent)) {
        return false;
    }
    if (!vuiPresent) {
        return pocType == 2;
    }
    // aspect_ratio_info
    if (!ffmpegBitReaderReadBits(&reader, 1, &flag)) {
        return false;
    }
    if (flag) {
        uint32_t aspectRatioIdc = 0;
        if (!ffmpegBitReaderReadBits(&reader, 8, &aspectRatioIdc)) {
            return false;
        }
        if (aspectRatioIdc == 255 && !ffmpegBitReaderReadBits(&reader, 32, &unused)) {
            return false;
        }
    }
    // overscan_info
    if (!ffmpegBitReaderReadBits(&reader, 1, &flag) || (flag && !ffmpegBitReaderReadBits(&reader, 1, &unused))) {
        return false;
    }
    // video_signal_type
    if (!ffmpegBitReaderReadBits(&reader, 1, &flag)) {
        return false;
    }
    if (flag) {
        uint32_t colourDescription = 0;
        if (!ffmpegBitReaderReadBits(&reader, 4, &unused) || !ffmpegBitReaderReadBits(&reader, 1, &colourDescription) || (colourDescription && !ffmpegBitReaderReadBits(&reader, 24, &unused))) {
            return false;
        }
    }
    // chroma_loc_info
    if (!ffmpegBitReaderReadBits(&reader, 1, &flag) || (flag && (!ffmpegBitReaderReadUE(&reader, &unused) || !ffmpegBitReaderReadUE(&reader, &unused)))) {
        return false;
    }
    // timing_info
    if (!ffmpegBitReaderReadBits(&reader, 1, &flag) || (flag && (!ffmpegBitReaderReadBits(&reader, 32, &unused) || !ffmpegBitReaderReadBits(&reader, 32, &unused) || !ffmpegBitReaderReadBits(&reader, 1, &unused)))) {
        return false;
    }
    uint32_t nalHrd = 0, vclHrd = 0;
    if (!ffmpegBitReaderReadBits(&reader, 1, &nalHrd) || (nalHrd && !ffmpegSkipHrdParameters(&reader))) {
        return false;
    }
    if (!ffmpegBitReaderReadBits(&reader, 1, &vclHrd) || (vclHrd && !ffmpegSkipHrdParameters(&reader))) {
        return false;
    }
    if ((nalHrd || vclHrd) && !ffmpegBitReaderReadBits(&reader, 1, &unused)) {
        return false;
    }
    // pic_struct_present_flag, bitstream_restriction_flag
    uint32_t bitstreamRestriction = 0;
    if (!ffmpegBitReaderReadBits(&reader, 1, &unused) || !ffmpegBitReaderReadBits(&reader, 1, &bitstreamRestriction)) {
        return false;
    }
    if (!bitstreamRestriction) {
        return pocType == 2;
    }
    // The rest must be present and small: FFmpeg drops a truncated restriction, reads these
    // with get_ue_golomb_31, and rejects num_reorder_frames above 16.
    if (!ffmpegBitReaderReadBits(&reader, 1, &unused)) {
        return false;
    }
    for (int i = 0; i < 6; i++) {
        uint32_t value = 0;
        if (!ffmpegBitReaderReadUE(&reader, &value) || value > 31) {
            return false;
        }
        if (i == 4 && value > 16) {
            return false;
        }
    }
    return true;
}

// Whether avformat_find_stream_info can leave this stream's decoder closed. It decodes
// frames only to learn the pixel format and, for H.264, the reorder delay. The decoder
// that plays the stream learns the pixel format itself, so this holds when the container
// header has the size and the reorder delay is known without decoding.
static bool ffmpegStreamInfoProbeCanSkipDecoding(const AVFormatContext *context, const AVStream *stream) {
    if (context->iformat == NULL || context->iformat->name == NULL) {
        return false;
    }
    bool isMov = strcmp(context->iformat->name, "mov,mp4,m4a,3gp,3g2,mj2") == 0;
    bool isMatroska = strcmp(context->iformat->name, "matroska,webm") == 0;
    if (!isMov && !isMatroska) {
        return false;
    }
    const AVCodecParameters *par = stream->codecpar;
    if (par->codec_type != AVMEDIA_TYPE_VIDEO || par->width <= 0 || par->height <= 0) {
        return false;
    }
    if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0) {
        return false;
    }
    switch (par->codec_id) {
        case AV_CODEC_ID_VP9:
            // VP9 does not reorder output.
            return true;
        case AV_CODEC_ID_HEVC:
            // The decoder takes the reorder depth from the SPS. mov only: matroska has no dts,
            // and FFmpeg guesses it from the probe decoder's delay.
            return isMov;
        case AV_CODEC_ID_H264:
            // mov derives the delay from the composition offsets of the whole sample table.
            // Fragmented files report 0, so 0 is trusted only when the SPS rules out reordering.
            if (!isMov) {
                return false;
            }
            return par->video_delay > 0 || ffmpegAvcCSignalsReorderDelay(par->extradata, par->extradata_size);
        default:
            return false;
    }
}
// Decoders the stream-info probe may open: all except those of codecs whose streams can all
// skip decoding. The same list goes to every stream, because avformat_find_stream_info can
// open one stream's decoder with another stream's options. nil when no stream can skip.
static NSString *ffmpegStreamInfoProbeCodecWhitelist(const AVFormatContext *context, int32_t *outSkippedStreamCount) {
    *outSkippedStreamCount = 0;
    NSMutableSet<NSNumber *> *blockedCodecIds = [[NSMutableSet alloc] init];
    NSMutableSet<NSNumber *> *probedCodecIds = [[NSMutableSet alloc] init];
    int32_t candidateCount = 0;
    for (unsigned int i = 0; i < context->nb_streams; i++) {
        const AVStream *stream = context->streams[i];
        if (ffmpegStreamInfoProbeCanSkipDecoding(context, stream)) {
            [blockedCodecIds addObject:@(stream->codecpar->codec_id)];
        } else {
            [probedCodecIds addObject:@(stream->codecpar->codec_id)];
        }
    }
    // A codec shared with a stream that needs the probe stays allowed.
    [blockedCodecIds minusSet:probedCodecIds];
    if (blockedCodecIds.count == 0) {
        return nil;
    }
    for (unsigned int i = 0; i < context->nb_streams; i++) {
        if ([blockedCodecIds containsObject:@(context->streams[i]->codecpar->codec_id)]) {
            candidateCount += 1;
        }
    }
    NSMutableArray<NSString *> *names = [[NSMutableArray alloc] init];
    void *iterator = NULL;
    const AVCodec *codec = NULL;
    while ((codec = av_codec_iterate(&iterator)) != NULL) {
        if (av_codec_is_decoder(codec) && codec->name != NULL && ![blockedCodecIds containsObject:@(codec->id)]) {
            [names addObject:[NSString stringWithUTF8String:codec->name]];
        }
    }
    *outSkippedStreamCount = candidateCount;
    return [names componentsJoinedByString:@","];
}

@interface FFMpegAVFormatContext () {
    AVFormatContext *_impl;
    int32_t _streamInfoProbeSkippedStreamCount;
}

@end

@implementation FFMpegAVFormatContext

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _impl = avformat_alloc_context();
    }
    return self;
}

- (void)dealloc {
    if (_impl != nil) {
        avformat_close_input(&_impl);
    }
}

- (void)setIOContext:(FFMpegAVIOContext *)ioContext {
    _impl->pb = [ioContext impl];
}

- (bool)openInputWithDirectFilePath:(NSString * _Nullable)directFilePath {
    return [self openInputWithDirectFilePath:directFilePath ignoreEditList:false];
}

- (bool)openInputWithDirectFilePath:(NSString * _Nullable)directFilePath ignoreEditList:(bool)ignoreEditList {
    AVDictionary *options = nil;
    av_dict_set(&options, "usetoc", "1", 0);
    if (ignoreEditList) {
        av_dict_set(&options, "ignore_editlist", "1", 0);
    }
    
    const char *url = "file";
    if (directFilePath) {
        url = [directFilePath UTF8String];
    }
    int result = avformat_open_input(&_impl, url, nil, &options);
    av_dict_free(&options);
    if (_impl != nil) {
        _impl->flags |= AVFMT_FLAG_FAST_SEEK;
        _impl->flags |= AVFMT_FLAG_NOBUFFER;
    }
    
    return result >= 0;
}

- (bool)findStreamInfo {
    return [self findStreamInfoWithFullProbe:false];
}

- (bool)findStreamInfoWithFullProbe:(bool)fullProbe {
    _streamInfoProbeSkippedStreamCount = 0;
    NSString *whitelist = nil;
    int32_t skippedStreamCount = 0;
    if (!fullProbe) {
        whitelist = ffmpegStreamInfoProbeCodecWhitelist(_impl, &skippedStreamCount);
    }
    if (whitelist != nil) {
        // The probe copies this into the options of every decoder it opens.
        _impl->codec_whitelist = av_strdup(whitelist.UTF8String);
        if (_impl->codec_whitelist == NULL) {
            skippedStreamCount = 0;
        }
    }
    int result = avformat_find_stream_info(_impl, nil);
    if (_impl->codec_whitelist != NULL) {
        av_freep(&_impl->codec_whitelist);
        _streamInfoProbeSkippedStreamCount = skippedStreamCount;
    }
    return result >= 0;
}

- (int32_t)streamInfoProbeSkippedStreamCount {
    return _streamInfoProbeSkippedStreamCount;
}

+ (bool)avcCSignalsReorderDelay:(NSData *)avcC {
    if (avcC.length > INT32_MAX) {
        return false;
    }
    return ffmpegAvcCSignalsReorderDelay(avcC.bytes, (int)avcC.length);
}

- (void)discardStreamsNotOfType:(FFMpegAVFormatStreamType)type {
    enum AVMediaType mediaType = type == FFMpegAVFormatStreamTypeAudio ? AVMEDIA_TYPE_AUDIO : AVMEDIA_TYPE_VIDEO;
    for (unsigned int i = 0; i < _impl->nb_streams; i++) {
        if (_impl->streams[i]->codecpar->codec_type != mediaType) {
            _impl->streams[i]->discard = AVDISCARD_ALL;
        }
    }
}

- (void)seekFrameForStreamIndex:(int32_t)streamIndex pts:(int64_t)pts positionOnKeyframe:(bool)positionOnKeyframe {
    int options = AVSEEK_FLAG_FRAME | AVSEEK_FLAG_BACKWARD;
    if (!positionOnKeyframe) {
        options |= AVSEEK_FLAG_ANY;
    }
    av_seek_frame(_impl, streamIndex, pts, options);
}

- (void)seekFrameForStreamIndex:(int32_t)streamIndex byteOffset:(int64_t)byteOffset {
    int options = AVSEEK_FLAG_BYTE;
    av_seek_frame(_impl, streamIndex, byteOffset, options);
}

- (bool)readFrameIntoPacket:(FFMpegPacket *)packet {
    [packet reuse];
    int result = av_read_frame(_impl, (AVPacket *)[packet impl]);
    return result >= 0;
}

- (NSArray<NSNumber *> *)streamIndicesForType:(FFMpegAVFormatStreamType)type {
    NSMutableArray<NSNumber *> *indices = [[NSMutableArray alloc] init];
    enum AVMediaType mediaType;
    switch(type) {
        case FFMpegAVFormatStreamTypeAudio:
            mediaType = AVMEDIA_TYPE_AUDIO;
            break;
        case FFMpegAVFormatStreamTypeVideo:
            mediaType = AVMEDIA_TYPE_VIDEO;
            break;
        default:
            mediaType = AVMEDIA_TYPE_VIDEO;
            break;
    }
    for (unsigned int i = 0; i < _impl->nb_streams; i++) {
        if (mediaType == _impl->streams[i]->codecpar->codec_type) {
            [indices addObject:@(i)];
        }
    }
    return indices;
}

- (bool)isAttachedPicAtStreamIndex:(int32_t)streamIndex {
    return ((_impl->streams[streamIndex]->disposition) & AV_DISPOSITION_ATTACHED_PIC) != 0;
}

- (int)codecIdAtStreamIndex:(int32_t)streamIndex {
    return _impl->streams[streamIndex]->codecpar->codec_id;
}

- (double)duration {
    return (double)_impl->duration / AV_TIME_BASE;
}

- (int64_t)startTimeAtStreamIndex:(int32_t)streamIndex {
    return _impl->streams[streamIndex]->start_time;
}

- (int64_t)durationAtStreamIndex:(int32_t)streamIndex {
    return _impl->streams[streamIndex]->duration;
}

- (int)numberOfIndexEntriesAtStreamIndex:(int32_t)streamIndex {
    return avformat_index_get_entries_count(_impl->streams[streamIndex]);
}

- (bool)fillIndexEntryAtStreamIndex:(int32_t)streamIndex entryIndex:(int32_t)entryIndex outEntry:(FFMpegAVIndexEntry * _Nonnull)outEntry {
    const AVIndexEntry *entry = avformat_index_get_entry(_impl->streams[streamIndex], entryIndex);
    if (!entry) {
        outEntry->pos = -1;
        outEntry->timestamp = 0;
        outEntry->isKeyframe = false;
        outEntry->size = 0;
        return false;
    }
    
    outEntry->pos = entry->pos;
    outEntry->timestamp = entry->timestamp;
    outEntry->isKeyframe = (entry->flags & AVINDEX_KEYFRAME) != 0;
    outEntry->size = entry->size;
    
    return true;
}

- (bool)codecParamsAtStreamIndex:(int32_t)streamIndex toContext:(FFMpegAVCodecContext *)context {
    int result = avcodec_parameters_to_context((AVCodecContext *)[context impl], _impl->streams[streamIndex]->codecpar);
    return result >= 0;
}

- (FFMpegFpsAndTimebase)fpsAndTimebaseForStreamIndex:(int32_t)streamIndex defaultTimeBase:(CMTime)defaultTimeBase {
    CMTime timebase;
    CMTime fps;
    
    AVStream *stream = _impl->streams[streamIndex];
    
    if (stream->time_base.den != 0 && stream->time_base.num != 0) {
        timebase = CMTimeMake((int64_t)stream->time_base.num, stream->time_base.den);
    }/* else if (stream->codec->time_base.den != 0 && stream->codec->time_base.num != 0) {
        timebase = CMTimeMake((int64_t)stream->codec->time_base.num, stream->codec->time_base.den);
    }*/ else {
        timebase = defaultTimeBase;
    }
    
    if (stream->avg_frame_rate.den != 0 && stream->avg_frame_rate.num != 0) {
        fps = CMTimeMake((int64_t)stream->avg_frame_rate.num, stream->avg_frame_rate.den);
    } else if (stream->r_frame_rate.den != 0 && stream->r_frame_rate.num != 0) {
        fps = CMTimeMake((int64_t)stream->r_frame_rate.num, stream->r_frame_rate.den);
    } else {
        fps = CMTimeMake(1, 24);
    }
    
    return (FFMpegFpsAndTimebase){ .fps = fps, .timebase = timebase };
}

- (FFMpegStreamMetrics)metricsForStreamAtIndex:(int32_t)streamIndex {
    int angleDegrees = get_stream_rotation(_impl->streams[streamIndex]);
    
    double rotationAngle = 0.0;
    rotationAngle = ((double)angleDegrees) * M_PI / 180.0;
    
    return (FFMpegStreamMetrics){ .width = _impl->streams[streamIndex]->codecpar->width, .height = _impl->streams[streamIndex]->codecpar->height, .rotationAngle = rotationAngle, .extradata = _impl->streams[streamIndex]->codecpar->extradata, .extradataSize = _impl->streams[streamIndex]->codecpar->extradata_size };
}

- (void)forceVideoCodecId:(int)videoCodecId {
    _impl->video_codec_id = videoCodecId;
    _impl->video_codec = avcodec_find_decoder(videoCodecId);
}

@end
