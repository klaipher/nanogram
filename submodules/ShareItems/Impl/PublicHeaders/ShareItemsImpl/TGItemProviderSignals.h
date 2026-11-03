#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@class MTSignal;

@interface TGItemProviderSignals : NSObject

/// One signal per attachment, each giving an item dictionary. `highQuality`: photos are scaled to a
/// 2560-pixel long side instead of 1280 ("Send in HD").
///
/// Attachments that can be large are loaded as files (`loadFileRepresentationForTypeIdentifier:`),
/// never into memory: videos, audio, GIFs and other files are cloned into their own directory under
/// `temporaryDirectory` and sent from there (`video`, `audio` or `path`); photos are downsampled
/// straight from the system's file. The caller owns `temporaryDirectory` and removes it when the
/// share ends.
+ (NSArray<MTSignal *> *)itemSignalsForInputItems:(NSArray *)inputItems highQuality:(bool)highQuality temporaryDirectory:(NSString *)temporaryDirectory;
/// A JPEG of the image in `data`, downsampled by ImageIO to at most `maxPixelSize` on its long
/// side without decoding the full image: `scaledImageData` (NSData) and `scaledImageDimensions`
/// (NSValue of CGSize). Nil when the data is not an image ImageIO can read.
+ (NSDictionary *)scaledJpegImageWithData:(NSData *)data maxPixelSize:(CGFloat)maxPixelSize;
/// The same, read from a file: only what the thumbnail needs is read.
+ (NSDictionary *)scaledJpegImageWithURL:(NSURL *)url maxPixelSize:(CGFloat)maxPixelSize;
/// A copy of the file at `url` in a new directory of its own inside `temporaryDirectory`, keeping its
/// name (an APFS clone when both are on one volume). Nil when it cannot be copied, including when
/// `temporaryDirectory` no longer exists: the share it belonged to has ended, and the copy would
/// outlive it.
+ (NSURL *)copyFileAtURL:(NSURL *)url toTemporaryDirectory:(NSString *)temporaryDirectory;
/// The waveform of a voice message (100 five-bit values) of the audio file at `url`, decoded in
/// full: call it only for a voice message, and off the main thread.
+ (NSData *)audioWaveform:(NSURL *)url;

@end

/// The peaks of 16-bit PCM audio, kept in a fixed amount of memory whatever the audio's length, and
/// the voice-message waveform made from them.
@interface TGAudioWaveformPeaks : NSObject

/// The most peaks kept; past it, neighbouring peaks are merged.
+ (NSUInteger)capacity;

- (void)addSamples:(const int16_t *)samples count:(NSUInteger)count;

/// How many peaks are kept now.
@property (nonatomic, readonly) NSUInteger storedPeakCount;

/// 100 int16 values: the largest peak in each hundredth of the audio.
- (NSData *)scaledPeaks;
/// The waveform as sent with a voice message: `scaledPeaks` as 100 five-bit values.
- (NSData *)waveform;

@end
