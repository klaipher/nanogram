#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WebP : NSObject
    
/// Decodes a still WebP at its stored size. Nil for corrupt, animated or oversized (more than 4096 pixels on a side) data.
+ (UIImage * _Nullable)convertFromWebP:(NSData * _Nonnull)data;
/// Like `convertFromWebP:`, but scaled down while decoding to fit `maxPixelSize` (never enlarged).
+ (UIImage * _Nullable)convertFromWebP:(NSData * _Nonnull)data fittingPixelSize:(CGSize)maxPixelSize;
+ (NSData * _Nullable)convertToWebP:(UIImage * _Nonnull)image quality:(CGFloat)quality error:(NSError ** _Nullable)error;

@end

NS_ASSUME_NONNULL_END
