#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

@class FFMpegAVIOContext;
@class FFMpegPacket;

typedef enum FFMpegAVFormatStreamType {
    FFMpegAVFormatStreamTypeVideo,
    FFMpegAVFormatStreamTypeAudio
} FFMpegAVFormatStreamType;

typedef struct FFMpegFpsAndTimebase {
    CMTime fps;
    CMTime timebase;
} FFMpegFpsAndTimebase;

typedef struct FFMpegStreamMetrics {
    int32_t width;
    int32_t height;
    double rotationAngle;
    uint8_t *extradata;
    int32_t extradataSize;
} FFMpegStreamMetrics;

typedef struct FFMpegAVIndexEntry {
    int64_t pos;
    int64_t timestamp;
    bool isKeyframe;
    int32_t size;
} FFMpegAVIndexEntry;

extern const int FFMpegCodecIdH264;
extern const int FFMpegCodecIdHEVC;
extern const int FFMpegCodecIdMPEG4;
extern const int FFMpegCodecIdVP9;
extern const int FFMpegCodecIdVP8;
extern const int FFMpegCodecIdAV1;

@class FFMpegAVCodecContext;

@interface FFMpegAVFormatContext : NSObject

- (instancetype)init;

- (void)setIOContext:(FFMpegAVIOContext *)ioContext;
- (bool)openInputWithDirectFilePath:(NSString * _Nullable)directFilePath;
- (bool)openInputWithDirectFilePath:(NSString * _Nullable)directFilePath ignoreEditList:(bool)ignoreEditList;
// Reads stream parameters. Streams whose container header already describes them are not
// decoded while probing (see FFMpegAVFormatContext.m); the decoder that plays them finds the
// pixel format itself.
- (bool)findStreamInfo;
// fullProbe: decode frames while probing as FFmpeg does by default. For tests.
- (bool)findStreamInfoWithFullProbe:(bool)fullProbe;
// Streams the last findStreamInfo did not decode. For tests.
@property (nonatomic, readonly) int32_t streamInfoProbeSkippedStreamCount;
// Whether an avcC record's SPS tells the H.264 decoder its reorder delay (POC type 2, or a
// VUI bitstream restriction), so the delay need not be guessed by decoding frames.
+ (bool)avcCSignalsReorderDelay:(NSData *)avcC;
// Marks every stream not of `type` discarded (`AVDISCARD_ALL`): `findStreamInfo` then analyses only streams of `type`,
// and reading returns no packets of the others.
- (void)discardStreamsNotOfType:(FFMpegAVFormatStreamType)type NS_SWIFT_NAME(discardStreams(notOf:));
- (void)seekFrameForStreamIndex:(int32_t)streamIndex pts:(int64_t)pts positionOnKeyframe:(bool)positionOnKeyframe;
- (void)seekFrameForStreamIndex:(int32_t)streamIndex byteOffset:(int64_t)byteOffset;
- (bool)readFrameIntoPacket:(FFMpegPacket *)packet;
- (NSArray<NSNumber *> *)streamIndicesForType:(FFMpegAVFormatStreamType)type;
- (bool)isAttachedPicAtStreamIndex:(int32_t)streamIndex;
- (int)codecIdAtStreamIndex:(int32_t)streamIndex;
- (double)duration;
- (int64_t)startTimeAtStreamIndex:(int32_t)streamIndex;
- (int64_t)durationAtStreamIndex:(int32_t)streamIndex;
- (int)numberOfIndexEntriesAtStreamIndex:(int32_t)streamIndex;
- (bool)fillIndexEntryAtStreamIndex:(int32_t)streamIndex entryIndex:(int32_t)entryIndex outEntry:(FFMpegAVIndexEntry * _Nonnull)outEntry;
- (bool)codecParamsAtStreamIndex:(int32_t)streamIndex toContext:(FFMpegAVCodecContext *)context;
- (FFMpegFpsAndTimebase)fpsAndTimebaseForStreamIndex:(int32_t)streamIndex defaultTimeBase:(CMTime)defaultTimeBase;
- (FFMpegStreamMetrics)metricsForStreamAtIndex:(int32_t)streamIndex;

- (void)forceVideoCodecId:(int)videoCodecId;

@end

NS_ASSUME_NONNULL_END
