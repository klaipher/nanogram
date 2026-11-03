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
+ (NSData *)audioWaveform:(NSURL *)url;

@end
