#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@class MTSignal;

@interface TGItemProviderSignals : NSObject

+ (NSArray<MTSignal *> *)itemSignalsForInputItems:(NSArray *)inputItems;
/// `highQuality`: photos are scaled to a 2560-pixel long side instead of 1280 ("Send in HD").
+ (NSArray<MTSignal *> *)itemSignalsForInputItems:(NSArray *)inputItems highQuality:(bool)highQuality;
/// A JPEG of the image in `data`, downsampled by ImageIO to at most `maxPixelSize` on its long
/// side without decoding the full image: `scaledImageData` (NSData) and `scaledImageDimensions`
/// (NSValue of CGSize). Nil when the data is not an image ImageIO can read.
+ (NSDictionary *)scaledJpegImageWithData:(NSData *)data maxPixelSize:(CGFloat)maxPixelSize;
+ (NSData *)audioWaveform:(NSURL *)url;

@end
