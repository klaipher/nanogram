#import <WebPBinding/UIImage+WebP.h>

#import "webp/encode.h"
#import "webp/decode.h"

@implementation WebP

/// Largest canvas side that is decoded at all. A WebP header can declare up to 16383 x 16383, which is a gigabyte of
/// pixels (and the same again for a mask) from a few dozen bytes of received content.
static const int WebPDecodeMaxSide = 4096;

static void WebPDecodedPixelsRelease(void *info, const void *data, size_t size) {
    free(info);
}

/// Decodes a still WebP to a premultiplied BGRA image of at most `maxPixelSize` (aspect fitted, never enlarged;
/// a zero size means the stored size), straight from the decoder with its own scaler: no UIGraphics context and no
/// second pass over the pixels. Everything allocated is released on every exit path.
static CGImageRef _Nullable WebPCreateImageFittingPixelSize(NSData * _Nonnull data, CGSize maxPixelSize) CF_RETURNS_RETAINED {
    if (data.length == 0) {
        return NULL;
    }
    WebPDecoderConfig config;
    if (!WebPInitDecoderConfig(&config)) {
        return NULL;
    }
    if (WebPGetFeatures(data.bytes, data.length, &config.input) != VP8_STATUS_OK) {
        return NULL;
    }
    if (config.input.has_animation || config.input.width < 1 || config.input.height < 1) {
        return NULL;
    }
    int sourceWidth = config.input.width;
    int sourceHeight = config.input.height;
    if (sourceWidth > WebPDecodeMaxSide || sourceHeight > WebPDecodeMaxSide) {
        return NULL;
    }
    double scale = 1.0;
    if (maxPixelSize.width >= 1.0 && maxPixelSize.height >= 1.0) {
        scale = MIN(1.0, MIN(maxPixelSize.width / sourceWidth, maxPixelSize.height / sourceHeight));
    }
    int width = MAX(1, (int)lround(sourceWidth * scale));
    int height = MAX(1, (int)lround(sourceHeight * scale));
    size_t bytesPerRow = (((size_t)width * 4) + 31) & ~(size_t)31;
    size_t length = bytesPerRow * (size_t)height;
    void *pixels = calloc(1, length);
    if (pixels == NULL) {
        return NULL;
    }
    if (width != sourceWidth || height != sourceHeight) {
        config.options.use_scaling = 1;
        config.options.scaled_width = width;
        config.options.scaled_height = height;
    }
    // Capital A: the decoder premultiplies the colors itself.
    config.output.colorspace = MODE_bgrA;
    config.output.is_external_memory = 1;
    config.output.u.RGBA.rgba = pixels;
    config.output.u.RGBA.stride = (int)bytesPerRow;
    config.output.u.RGBA.size = length;
    VP8StatusCode status = WebPDecode(data.bytes, data.length, &config);
    WebPFreeDecBuffer(&config.output);
    if (status != VP8_STATUS_OK) {
        free(pixels);
        return NULL;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(pixels, pixels, length, WebPDecodedPixelsRelease);
    if (provider == NULL) {
        free(pixels);
        return NULL;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(width, height, 8, 32, bytesPerRow, colorSpace, kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    return image;
}

+ (UIImage * _Nullable)convertFromWebP:(NSData * _Nonnull)imgData {
    return [self convertFromWebP:imgData fittingPixelSize:CGSizeZero];
}

+ (UIImage * _Nullable)convertFromWebP:(NSData * _Nonnull)imgData fittingPixelSize:(CGSize)maxPixelSize {
    if (imgData == nil) {
        return nil;
    }
    CGImageRef bitmapImage = WebPCreateImageFittingPixelSize(imgData, maxPixelSize);
    if (bitmapImage == NULL) {
        return nil;
    }
    UIImage *image = [[UIImage alloc] initWithCGImage:bitmapImage scale:1.0f orientation:UIImageOrientationUp];
    CGImageRelease(bitmapImage);
    return image;
}
    
+ (NSData * _Nullable)convertToWebP:(UIImage * _Nonnull)image quality:(CGFloat)quality error:(NSError ** _Nullable)error {
    WebPPreset preset = WEBP_PRESET_DEFAULT;
    CGImageRef imageRef = [image CGImage];

    NSUInteger width = CGImageGetWidth(imageRef);
    NSUInteger height = CGImageGetHeight(imageRef);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    uint8_t *rawData = malloc(height * width * 4);

    NSUInteger bytesPerPixel = 4;
    NSUInteger bytesPerRow = bytesPerPixel * width;
    NSUInteger bitsPerComponent = 8;
    CGContextRef context = CGBitmapContextCreate(rawData, width, height, bitsPerComponent, bytesPerRow, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);

    CGContextClearRect(context, CGRectMake(0, 0, width, height));
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), imageRef);
    CGContextRelease(context);

    WebPConfig config;
    if (!WebPConfigPreset(&config, preset, quality)) {
        NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
        [errorDetail setValue:@"Configuration preset failed to initialize." forKey:NSLocalizedDescriptionKey];
        if(error != NULL)
        *error = [NSError errorWithDomain:[NSString stringWithFormat:@"%@.errorDomain",  [[NSBundle mainBundle] bundleIdentifier]] code:-101 userInfo:errorDetail];
        
        free(rawData);
        return nil;
    }
    
    config.method = 6;
    
    if (!WebPValidateConfig(&config)) {
        NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
        [errorDetail setValue:@"One or more configuration parameters are beyond their valid ranges." forKey:NSLocalizedDescriptionKey];
        if(error != NULL)
        *error = [NSError errorWithDomain:[NSString stringWithFormat:@"%@.errorDomain",  [[NSBundle mainBundle] bundleIdentifier]] code:-101 userInfo:errorDetail];
        
        free(rawData);
        return nil;
    }
    
    WebPPicture pic;
    if (!WebPPictureInit(&pic)) {
        NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
        [errorDetail setValue:@"Failed to initialize structure. Version mismatch." forKey:NSLocalizedDescriptionKey];
        if(error != NULL)
        *error = [NSError errorWithDomain:[NSString stringWithFormat:@"%@.errorDomain",  [[NSBundle mainBundle] bundleIdentifier]] code:-101 userInfo:errorDetail];
        
        free(rawData);
        return nil;
    }
    pic.width = (int)width;
    pic.height = (int)height;
    pic.colorspace = WEBP_YUV420;
    
    
//    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){12, 0, 0}]) {
        WebPPictureImportRGBA(&pic, rawData, (int)bytesPerRow);
//    } else {
//        WebPPictureImportBGRA(&pic, webPImageData, (int)webPBytesPerRow);
//    }
    
    WebPPictureARGBToYUVA(&pic, WEBP_YUV420);
    WebPCleanupTransparentArea(&pic);
    
    WebPMemoryWriter writer;
    WebPMemoryWriterInit(&writer);
    pic.writer = WebPMemoryWrite;
    pic.custom_ptr = &writer;
    WebPEncode(&config, &pic);
    
    NSData *webPFinalData = [NSData dataWithBytes:writer.mem length:writer.size];
    
    free(writer.mem);
    WebPPictureFree(&pic);
    free(rawData);
    
    return webPFinalData;
}


@end
