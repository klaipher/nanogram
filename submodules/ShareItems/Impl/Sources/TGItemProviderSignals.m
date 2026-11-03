#import <ShareItemsImpl/TGItemProviderSignals.h>

#import <MtProtoKit/MtProtoKit.h>

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AddressBook/AddressBook.h>
#import <AVFoundation/AVFoundation.h>
#import <PassKit/PassKit.h>

#import <MimeTypes/MimeTypes.h>

static const CGFloat TGShareImageMaxPixelSize = 1280.0;
static const CGFloat TGShareImageHighQualityMaxPixelSize = 2560.0;

@implementation TGItemProviderSignals

+ (NSArray<MTSignal *> *)itemSignalsForInputItems:(NSArray *)inputItems
{
    return [self itemSignalsForInputItems:inputItems highQuality:false];
}

+ (NSArray<MTSignal *> *)itemSignalsForInputItems:(NSArray *)inputItems highQuality:(bool)highQuality
{
    NSMutableArray *itemSignals = [[NSMutableArray alloc] init];
    NSMutableArray *providers = [[NSMutableArray alloc] init];
    
    for (NSExtensionItem *item in inputItems)
    {
        for (NSItemProvider *provider in item.attachments)
        {
            if ([provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier])
                [providers addObject:provider];
            else if ([provider hasItemConformingToTypeIdentifier:UTTypeAudio.identifier])
                [providers addObject:provider];
            else if ([provider hasItemConformingToTypeIdentifier:UTTypeImage.identifier])
                [providers addObject:provider];
            else if ([provider hasItemConformingToTypeIdentifier:UTTypeFileURL.identifier])
                [providers addObject:provider];
            else if ([provider hasItemConformingToTypeIdentifier:UTTypeURL.identifier]) {
                [providers removeAllObjects];
                
                [providers addObject:provider];
                break;
            }
            else if ([provider hasItemConformingToTypeIdentifier:UTTypeVCard.identifier])
                [providers addObject:provider];
            else if ([provider hasItemConformingToTypeIdentifier:UTTypeText.identifier])
                [providers addObject:provider];
            else if ([provider hasItemConformingToTypeIdentifier:UTTypeData.identifier])
                [providers addObject:provider];
            else if ([provider hasItemConformingToTypeIdentifier:@"com.apple.pkpass"])
                [providers addObject:provider];
        }
    }
    
    __unused NSInteger providerIndex = -1;
    for (NSItemProvider *provider in providers)
    {
        providerIndex++;
        
        MTSignal *dataSignal = nil;
        if ([provider hasItemConformingToTypeIdentifier:UTTypeAudio.identifier])
            dataSignal = [self signalForAudioItemProvider:provider];
        else if ([provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier])
            dataSignal = [self signalForVideoItemProvider:provider];
        else if ([provider hasItemConformingToTypeIdentifier:UTTypeGIF.identifier])
            dataSignal = [self signalForDataItemProvider:provider];
        else if ([provider hasItemConformingToTypeIdentifier:UTTypeImage.identifier])
            dataSignal = [self signalForImageItemProvider:provider maxPixelSize:highQuality ? TGShareImageHighQualityMaxPixelSize : TGShareImageMaxPixelSize];
        else if ([provider hasItemConformingToTypeIdentifier:UTTypeFileURL.identifier])
        {
            dataSignal = [[self signalForUrlItemProvider:provider] mapToSignal:^MTSignal *(NSURL *url)
            {
                NSData *data = [[NSData alloc] initWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
                if (data == nil)
                    return [MTSignal fail:nil];
                NSString *fileName = [[url pathComponents] lastObject];
                if (fileName.length == 0)
                    fileName = @"file.bin";
                NSString *extension = [fileName pathExtension];
                NSString *mimeType = [TGMimeTypeMap mimeTypeForExtension:[extension lowercaseString]];
                if (mimeType == nil)
                    mimeType = @"application/octet-stream";
                return [MTSignal single:@{@"data": data, @"fileName": fileName, @"mimeType": mimeType}];
            }];
        }
        else if ([provider hasItemConformingToTypeIdentifier:UTTypeVCard.identifier])
            dataSignal = [self signalForVCardItemProvider:provider];
        else if ([provider hasItemConformingToTypeIdentifier:UTTypeText.identifier])
            dataSignal = [self signalForTextItemProvider:provider];
        else if ([provider hasItemConformingToTypeIdentifier:UTTypeURL.identifier])
            dataSignal = [self signalForTextUrlItemProvider:provider];
        else if ([provider hasItemConformingToTypeIdentifier:UTTypeData.identifier])
        {
            dataSignal = [[self signalForDataItemProvider:provider] map:^id(NSDictionary *dict)
            {
                if (dict[@"fileName"] == nil)
                {
                    NSMutableDictionary *updatedDict = [[NSMutableDictionary alloc] initWithDictionary:dict];
                    for (NSString *typeIdentifier in provider.registeredTypeIdentifiers)
                    {
                        NSString *extension = [TGMimeTypeMap extensionForMimeType:typeIdentifier];
                        if (extension == nil)
                            extension = [TGMimeTypeMap extensionForMimeType:[@"application/" stringByAppendingString:typeIdentifier]];
                        
                        if (extension != nil) {
                            updatedDict[@"fileName"] = [@"file" stringByAppendingPathExtension:extension];
                            updatedDict[@"mimeType"] = [TGMimeTypeMap mimeTypeForExtension:extension];
                        }
                    }
                    return updatedDict;
                }
                else
                {
                    return dict;
                }
            }];
        }
        else if ([provider hasItemConformingToTypeIdentifier:@"com.apple.pkpass"])
        {
            dataSignal = [self signalForPassKitItemProvider:provider];
        }

        if (dataSignal != nil)
            [itemSignals addObject:dataSignal];
    }
    
    return itemSignals;
}

+ (MTSignal *)signalForDataItemProvider:(NSItemProvider *)itemProvider
{
    return [[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber)
    {
        [itemProvider loadItemForTypeIdentifier:UTTypeData.identifier options:nil completionHandler:^(NSData *data, NSError *error)
        {
            if (error != nil || ![data isKindOfClass:[NSData class]])
                [subscriber putError:nil];
            else
            {
                [subscriber putNext:@{@"data": data}];
                [subscriber putCompletion];
            }
        }];
        
        return nil;
    }];
}

+ (NSDictionary *)scaledJpegImageFromSource:(CGImageSourceRef)source maxPixelSize:(CGFloat)maxPixelSize
{
    if (source == NULL) {
        return nil;
    }
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceShouldCacheImmediately: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize)
    };
    // A +1 reference: ARC does not manage CF types, so every exit below releases it.
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    if (image == NULL) {
        return nil;
    }
    CGSize dimensions = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
    
    // Encoded in memory: a temporary file per photo was never removed.
    NSMutableData *jpegData = [[NSMutableData alloc] init];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpegData, (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
    if (destination == NULL) {
        CGImageRelease(image);
        return nil;
    }
    NSDictionary *properties = @{ (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(0.52) };
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)properties);
    CGImageDestinationAddImage(destination, image, nil);
    bool finalized = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    
    if (!finalized || jpegData.length == 0) {
        return nil;
    }
    return @{@"scaledImageData": jpegData, @"scaledImageDimensions": [NSValue valueWithCGSize:dimensions]};
}

+ (NSDictionary *)scaledJpegImageWithData:(NSData *)data maxPixelSize:(CGFloat)maxPixelSize
{
    if (data == nil) {
        return nil;
    }
    NSDictionary *sourceOptions = @{ (id)kCGImageSourceShouldCache: @NO };
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)sourceOptions);
    if (source == NULL) {
        return nil;
    }
    NSDictionary *result = [self scaledJpegImageFromSource:source maxPixelSize:maxPixelSize];
    CFRelease(source);
    return result;
}

+ (NSDictionary *)scaledJpegImageWithURL:(NSURL *)url maxPixelSize:(CGFloat)maxPixelSize
{
    if (url == nil) {
        return nil;
    }
    NSDictionary *sourceOptions = @{ (id)kCGImageSourceShouldCache: @NO };
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)sourceOptions);
    if (source == NULL) {
        return nil;
    }
    NSDictionary *result = [self scaledJpegImageFromSource:source maxPixelSize:maxPixelSize];
    CFRelease(source);
    return result;
}

+ (MTSignal *)signalForImageItemProvider:(NSItemProvider *)itemProvider maxPixelSize:(CGFloat)maxPixelSize
{
    return [[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber)
    {
        CGSize maxSize = CGSizeMake(maxPixelSize, maxPixelSize);
        NSDictionary *imageOptions = @{
            NSItemProviderPreferredImageSizeKey: [NSValue valueWithCGSize:maxSize]
        };
        if ([itemProvider hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) {
            [itemProvider loadItemForTypeIdentifier:UTTypeImage.identifier options:imageOptions completionHandler:^(id<NSSecureCoding> _Nullable item, NSError * _Null_unspecified error) {
                if (error != nil && ![(NSObject *)item respondsToSelector:@selector(CGImage)] && ![(NSObject *)item respondsToSelector:@selector(absoluteString)]) {
                    [itemProvider loadItemForTypeIdentifier:UTTypeData.identifier options:nil completionHandler:^(NSData *data, NSError *error)
                     {
                         if (error != nil || ![data isKindOfClass:[NSData class]])
                             [subscriber putError:nil];
                         else
                         {
                             [subscriber putNext:@{@"data": data, @"maxImagePixelSize": @(maxPixelSize)}];
                             [subscriber putCompletion];
                         }
                     }];
                } else {
                    if ([(NSObject *)item respondsToSelector:@selector(absoluteString)]) {
                        NSDictionary *result = [self scaledJpegImageWithURL:(NSURL *)item maxPixelSize:maxPixelSize];
                        if (result != nil) {
                            [subscriber putNext:result];
                            [subscriber putCompletion];
                        } else {
                            [subscriber putError:nil];
                        }
                    } else if ([(NSObject *)item isKindOfClass:[NSData class]]) {
                        [subscriber putNext:@{@"data": item, @"maxImagePixelSize": @(maxPixelSize)}];
                        [subscriber putCompletion];
                    } else if ([(NSObject *)item isKindOfClass:[UIImage class]]) {
                        [subscriber putNext:@{@"image": item, @"maxImagePixelSize": @(maxPixelSize)}];
                        [subscriber putCompletion];
                    } else {
                        [subscriber putError:nil];
                    }
                }
            }];
        } else {
            [itemProvider loadItemForTypeIdentifier:UTTypeData.identifier options:nil completionHandler:^(NSData *data, NSError *error)
             {
                 if (error != nil || ![data isKindOfClass:[NSData class]])
                     [subscriber putError:nil];
                 else
                 {
                     [subscriber putNext:@{@"data": data, @"maxImagePixelSize": @(maxPixelSize)}];
                     [subscriber putCompletion];
                 }
             }];
        }
        
        return nil;
    }];
}

+ (MTSignal *)signalForAudioItemProvider:(NSItemProvider *)itemProvider
{
    MTSignal *itemSignal = [[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber)
    {
        [itemProvider loadItemForTypeIdentifier:UTTypeAudio.identifier options:nil completionHandler:^(NSURL *url, NSError *error)
        {
            if (error != nil || ![url isKindOfClass:[NSURL class]])
               [subscriber putError:nil];
            else
            {
                [subscriber putNext:url];
                [subscriber putCompletion];
            }
        }];
        return nil;
    }];
    
    return [itemSignal mapToSignal:^MTSignal *(NSURL *url)
    {
        if (![url isKindOfClass:[NSURL class]])
            return [MTSignal fail:nil];
        AVAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        if (asset == nil)
            return [MTSignal fail:nil];
        
        NSString *extension = url.pathExtension;
        NSString *mimeType = [TGMimeTypeMap mimeTypeForExtension:[extension lowercaseString]];
        if (mimeType == nil)
            mimeType = @"application/octet-stream";
        
        NSString *title = (NSString *)[[AVMetadataItem metadataItemsFromArray:asset.commonMetadata withKey:AVMetadataCommonKeyTitle keySpace:AVMetadataKeySpaceCommon] firstObject];
        NSString *artist = (NSString *)[[AVMetadataItem metadataItemsFromArray:asset.commonMetadata withKey:AVMetadataCommonKeyArtist keySpace:AVMetadataKeySpaceCommon] firstObject];
        
        NSString *software = nil;
        AVMetadataItem *softwareItem = [[AVMetadataItem metadataItemsFromArray:asset.commonMetadata withKey:AVMetadataCommonKeySoftware keySpace:AVMetadataKeySpaceCommon] firstObject];
        if ([softwareItem isKindOfClass:[AVMetadataItem class]] && ([softwareItem.value isKindOfClass:[NSString class]]))
            software = (NSString *)[softwareItem value];
        
        bool isVoice = [software hasPrefix:@"com.apple.VoiceMemos"];
            
        NSTimeInterval duration =  CMTimeGetSeconds(asset.duration);
        
        NSMutableDictionary *result = [[NSMutableDictionary alloc] init];
        result[@"audio"] = url;
        result[@"mimeType"] = mimeType;
        result[@"duration"] = @(duration);
        result[@"isVoice"] = @(isVoice);
        
        NSString *artistString = @"";
        if ([artist respondsToSelector:@selector(characterAtIndex:)]) {
            artistString = artist;
        } else if ([artist isKindOfClass:[AVMetadataItem class]]) {
            artistString = [(AVMetadataItem *)artist stringValue];
        }
        
        NSString *titleString = @"";
        if ([artist respondsToSelector:@selector(characterAtIndex:)]) {
            titleString = title;
        } else if ([title isKindOfClass:[AVMetadataItem class]]) {
            titleString = [(AVMetadataItem *)title stringValue];
        }
        
        if (artistString.length > 0)
            result[@"artist"] = artistString;
        if (titleString.length > 0)
            result[@"title"] = titleString;
        
        return [MTSignal single:result];
    }];
}

+ (MTSignal *)detectRoundVideo:(AVAsset *)asset
{
    MTSignal *imageSignal = [[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subsriber)
    {
        AVAssetImageGenerator *imageGenerator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        imageGenerator.appliesPreferredTrackTransform = true;
        // Only the four corners are read: a small frame is enough, not a full-resolution copy.
        imageGenerator.maximumSize = CGSizeMake(64.0, 64.0);
        [imageGenerator generateCGImagesAsynchronouslyForTimes:@[ [NSValue valueWithCMTime:kCMTimeZero] ] completionHandler:^(CMTime requestedTime, CGImageRef  _Nullable image, CMTime actualTime, AVAssetImageGeneratorResult result, NSError * _Nullable error)
        {
            if (error != nil || image == NULL)
            {
                [subsriber putError:nil];
            }
            else
            {
                [subsriber putNext:@([self imageHasWhiteCorners:image])];
                [subsriber putCompletion];
            }
        }];
        
        return [[MTBlockDisposable alloc] initWithBlock:^
        {
            [imageGenerator cancelAllCGImageGeneration];
        }];
    }];
    
    // A frame that cannot be read is sent as an ordinary video rather than failing the share.
    return [imageSignal catch:^MTSignal *(__unused id error) {
        return [MTSignal single:@false];
    }];
}

+ (bool)imageHasWhiteCorners:(CGImageRef)image
{
    // Drawn into a bitmap of known layout, so neither the source's pixel format nor its row
    // padding decides which bytes are read.
    const size_t width = MAX((size_t)1, MIN(CGImageGetWidth(image), (size_t)64));
    const size_t height = MAX((size_t)1, MIN(CGImageGetHeight(image), (size_t)64));
    const size_t bytesPerRow = width * 4;
    uint8_t *pixels = calloc(height, bytesPerRow);
    if (pixels == NULL) {
        return false;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, bytesPerRow, colorSpace, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        free(pixels);
        return false;
    }
    CGContextDrawImage(context, CGRectMake(0.0, 0.0, width, height), image);
    CGContextRelease(context);
    
    bool (^isWhitePixel)(size_t, size_t) = ^bool(size_t x, size_t y) {
        const uint8_t *pixel = pixels + y * bytesPerRow + x * 4;
        return pixel[0] > 250 && pixel[1] > 250 && pixel[2] > 250;
    };
    bool result = isWhitePixel(0, 0) && isWhitePixel(width - 1, 0) && isWhitePixel(0, height - 1) && isWhitePixel(width - 1, height - 1);
    free(pixels);
    return result;
}

+ (MTSignal *)signalForVideoItemProvider:(NSItemProvider *)itemProvider
{
    MTSignal *assetSignal = [[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber)
    {
        [itemProvider loadItemForTypeIdentifier:UTTypeMovie.identifier options:nil completionHandler:^(NSURL *url, NSError *error)
        {
            if (error != nil || ![url isKindOfClass:[NSURL class]])
            {
                [subscriber putError:nil];
            }
            else
            {
                AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:url options:nil];
                // Loaded here, off the provider's callback, so the synchronous reads below do not block on I/O.
                [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"metadata", @"duration"] completionHandler:^{
                    [subscriber putNext:asset];
                    [subscriber putCompletion];
                }];
            }
        }];
        
        return nil;
    }];
    
    return [assetSignal mapToSignal:^MTSignal *(AVURLAsset *asset)
    {
        AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (videoTrack == nil)
        {
            // A movie with no video track (an audio-only .mov or .m4v) is sent as a file.
            NSData *data = [[NSData alloc] initWithContentsOfURL:asset.URL options:NSDataReadingMappedIfSafe error:nil];
            if (data == nil)
                return [MTSignal fail:nil];
            NSString *fileName = asset.URL.lastPathComponent;
            if (fileName.length == 0)
                fileName = @"file.bin";
            NSString *mimeType = [TGMimeTypeMap mimeTypeForExtension:[fileName.pathExtension lowercaseString]];
            if (mimeType == nil)
                mimeType = @"application/octet-stream";
            return [MTSignal single:@{@"data": data, @"fileName": fileName, @"mimeType": mimeType, @"treatAsFile": @true}];
        }
        else
        {
            CGSize dimensions = CGRectApplyAffineTransform((CGRect){CGPointZero, videoTrack.naturalSize}, videoTrack.preferredTransform).size;
            NSString *extension = asset.URL.pathExtension;
            NSString *mimeType = [TGMimeTypeMap mimeTypeForExtension:[extension lowercaseString]];
            if (mimeType == nil)
                mimeType = @"application/octet-stream";
            
            NSString *software = nil;
            AVMetadataItem *softwareItem = [[AVMetadataItem metadataItemsFromArray:asset.metadata withKey:AVMetadataCommonKeySoftware keySpace:AVMetadataKeySpaceCommon] firstObject];
            if ([softwareItem isKindOfClass:[AVMetadataItem class]] && ([softwareItem.value isKindOfClass:[NSString class]]))
                software = (NSString *)[softwareItem value];
            
            bool isAnimation = false;
            if ([software hasPrefix:@"Boomerang"])
                isAnimation = true;
            
            if (isAnimation || fabs(dimensions.width - dimensions.height) > FLT_EPSILON)
            {
                return [MTSignal single:@{@"video": asset, @"mimeType": mimeType, @"isAnimation": @(isAnimation), @"width": @(dimensions.width), @"height": @(dimensions.height)}];
            }
            else
            {
                return [[self detectRoundVideo:asset] mapToSignal:^MTSignal *(NSNumber *isRoundVideo)
                {
                    return [MTSignal single:@{@"video": asset, @"mimeType": mimeType, @"isAnimation": @(isAnimation), @"width": @(dimensions.width), @"height": @(dimensions.height), @"isRoundMessage": isRoundVideo}];
                }];
            }
        }
    }];
}

+ (MTSignal *)signalForUrlItemProvider:(NSItemProvider *)itemProvider
{
    return [[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber)
    {
        [itemProvider loadItemForTypeIdentifier:UTTypeFileURL.identifier options:nil completionHandler:^(NSURL *url, NSError *error)
        {
            if (error != nil || ![url isKindOfClass:[NSURL class]])
                [subscriber putError:nil];
            else
            {
                [subscriber putNext:url];
                [subscriber putCompletion];
            }
        }];
        
        return nil;
    }];
}

+ (MTSignal *)signalForTextItemProvider:(NSItemProvider *)itemProvider
{
    return [[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber)
    {
        [itemProvider loadItemForTypeIdentifier:UTTypeText.identifier options:nil completionHandler:^(NSString *text, NSError *error)
        {
            if (error != nil || ![text isKindOfClass:[NSString class]])
                [subscriber putError:nil];
            else
            {
                [subscriber putNext:@{@"text": text}];
                [subscriber putCompletion];
            }
        }];
        
        return nil;
    }];
}

+ (MTSignal *)signalForTextUrlItemProvider:(NSItemProvider *)itemProvider
{
    return [[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber)
    {
        [itemProvider loadItemForTypeIdentifier:UTTypeURL.identifier options:nil completionHandler:^(NSURL *url, NSError *error)
        {
            if (error != nil || ![url isKindOfClass:[NSURL class]])
                [subscriber putError:nil];
            else
            {
                [subscriber putNext:@{@"url": url}];
                [subscriber putCompletion];
            }
        }];
        
        return nil;
    }];
}

+ (MTSignal *)signalForVCardItemProvider:(NSItemProvider *)itemProvider
{
    return [[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber)
    {
        [itemProvider loadItemForTypeIdentifier:UTTypeVCard.identifier options:nil completionHandler:^(NSData *vcard, NSError *error)
        {
            if (error != nil || ![vcard isKindOfClass:[NSData class]])
                [subscriber putError:nil];
            else
            {
                [subscriber putNext:@{@"contact": vcard}];
                [subscriber putCompletion];
            }
        }];
        
        return nil;
    }];
}

+ (MTSignal *)signalForPassKitItemProvider:(NSItemProvider *)itemProvider
{
    return [[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber)
    {
        [itemProvider loadItemForTypeIdentifier:@"com.apple.pkpass" options:nil completionHandler:^(id data, NSError *error)
        {
            if (error != nil || ![data isKindOfClass:[NSData class]])
            {
                [subscriber putError:nil];
            }
            else
            {
                NSError *parseError;
                PKPass *pass = [[PKPass alloc] initWithData:data error:&parseError];
                if (parseError != nil)
                {
                    [subscriber putError:nil];
                }
                else
                {
                    NSString *fileName = [NSString stringWithFormat:@"%@.pkpass", pass.serialNumber];
                    [subscriber putNext:@{@"data": data, @"fileName": fileName, @"mimeType": @"application/vnd.apple.pkpass"}];
                    [subscriber putCompletion];
                }
            }
        }];
        
        return nil;
    }];
}

static void set_bits(uint8_t *bytes, int32_t bitOffset, int32_t numBits, int32_t value) {
    numBits = (unsigned int)pow(2, numBits) - 1; //this will only work up to 32 bits, of course
    uint8_t *data = bytes;
    data += bitOffset / 8;
    bitOffset %= 8;
    *((int32_t *)data) |= ((value) << bitOffset);
}

+ (NSData *)audioWaveform:(NSURL *)url {
    NSDictionary *outputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                    [NSNumber numberWithInt:kAudioFormatLinearPCM], AVFormatIDKey,
                                    [NSNumber numberWithFloat:44100.0], AVSampleRateKey,
                                    [NSNumber numberWithInt:16], AVLinearPCMBitDepthKey,
                                    [NSNumber numberWithBool:NO], AVLinearPCMIsNonInterleaved,
                                    [NSNumber numberWithBool:NO], AVLinearPCMIsFloatKey,
                                    [NSNumber numberWithBool:NO], AVLinearPCMIsBigEndianKey,
                                    nil];
    
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    if (asset == nil) {
        NSLog(@"asset is not defined!");
        return nil;
    }
    
    NSError *assetError = nil;
    AVAssetReader *iPodAssetReader = [AVAssetReader assetReaderWithAsset:asset error:&assetError];
    if (assetError) {
        NSLog (@"error: %@", assetError);
        return nil;
    }
    
    AVAssetReaderOutput *readerOutput = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:asset.tracks audioSettings:outputSettings];
    
    if (! [iPodAssetReader canAddOutput: readerOutput]) {
        NSLog (@"can't add reader output... die!");
        return nil;
    }
    
    // add output reader to reader
    [iPodAssetReader addOutput: readerOutput];
    
    if (![iPodAssetReader startReading]) {
        NSLog(@"Unable to start reading!");
        return nil;
    }
    
    NSMutableData *_waveformSamples = [[NSMutableData alloc] init];
    int16_t _waveformPeak = 0;
    int _waveformPeakCount = 0;
    
    while (iPodAssetReader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef nextBuffer = [readerOutput copyNextSampleBuffer];
        
        if (nextBuffer) {
            AudioBufferList abl;
            CMBlockBufferRef blockBuffer = NULL;
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(nextBuffer, NULL, &abl, sizeof(abl), NULL, NULL, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &blockBuffer);
            UInt64 size = CMSampleBufferGetTotalSampleSize(nextBuffer);
            if (size != 0) {
                int16_t *samples = (int16_t *)(abl.mBuffers[0].mData);
                int count = (int)size / 2;
                
                for (int i = 0; i < count; i++) {
                    int16_t sample = samples[i];
                    if (sample < 0) {
                        sample = -sample;
                    }
                    
                    if (_waveformPeak < sample) {
                        _waveformPeak = sample;
                    }
                    _waveformPeakCount++;
                    
                    if (_waveformPeakCount >= 100) {
                        [_waveformSamples appendBytes:&_waveformPeak length:2];
                        _waveformPeak = 0;
                        _waveformPeakCount = 0;
                    }
                }
            }
            
            CFRelease(nextBuffer);
            if (blockBuffer) {
                CFRelease(blockBuffer);
            }
        }
        else {
            break;
        }
    }
    
    int16_t scaledSamples[100];
    memset(scaledSamples, 0, 100 * 2);
    int16_t *samples = _waveformSamples.mutableBytes;
    int count = (int)_waveformSamples.length / 2;
    for (int i = 0; i < count; i++) {
        int16_t sample = samples[i];
        int index = i * 100 / count;
        if (scaledSamples[index] < sample) {
            scaledSamples[index] = sample;
        }
    }
    
    int16_t peak = 0;
    int64_t sumSamples = 0;
    for (int i = 0; i < 100; i++) {
        int16_t sample = scaledSamples[i];
        if (peak < sample) {
            peak = sample;
        }
        sumSamples += sample;
    }
    uint16_t calculatedPeak = 0;
    calculatedPeak = (uint16_t)(sumSamples * 1.8f / 100);
    
    if (calculatedPeak < 2500) {
        calculatedPeak = 2500;
    }
    
    for (int i = 0; i < 100; i++) {
        uint16_t sample = (uint16_t)((int64_t)samples[i]);
        if (sample > calculatedPeak) {
            scaledSamples[i] = calculatedPeak;
        }
    }
    
    int numSamples = 100;
    int bitstreamLength = (numSamples * 5) / 8 + (((numSamples * 5) % 8) == 0 ? 0 : 1);
    NSMutableData *result = [[NSMutableData alloc] initWithLength:bitstreamLength];
    {
        int32_t maxSample = peak;
        uint16_t const *samples = (uint16_t *)scaledSamples;
        uint8_t *bytes = result.mutableBytes;
        
        for (int i = 0; i < numSamples; i++) {
            int32_t value = MIN(31, ABS((int32_t)samples[i]) * 31 / maxSample);
            set_bits(bytes, i * 5, 5, value & 31);
        }
    }
    
    return result;
}

@end
