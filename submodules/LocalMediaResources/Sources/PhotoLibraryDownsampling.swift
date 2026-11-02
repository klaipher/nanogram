import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// The size a library photo is sent at: `maxSize` fitted inside the photo's oriented pixel size,
/// floored, never upscaled. The same arithmetic the full-size path has always used.
func photoLibraryUploadSize(orientedPixelSize: CGSize, maxSize: CGSize) -> CGSize {
    let scale = min(1.0, min(maxSize.width / max(1.0, orientedPixelSize.width), maxSize.height / max(1.0, orientedPixelSize.height)))
    return CGSize(width: floor(orientedPixelSize.width * scale), height: floor(orientedPixelSize.height * scale))
}

/// A gallery photo scaled for upload straight from its encoded data.
///
/// The full-size path asked PhotoKit for the whole 24/48 MP photo and scaled it on the CPU, about
/// 300-430 MB peak per photo (3 photos in flight in an album send). ImageIO's thumbnail decoder
/// decodes at a reduced size (in hardware for HEIC) and applies the EXIF orientation, so peak
/// memory is the target size. The result then goes through the same `resizedImage` step as before,
/// which fixes the exact output size and converts to the same 8-bit sRGB.
///
/// Returns nil for photos this path does not reproduce faithfully, so the caller falls back to
/// the full-size path: deeper than 8 bits per channel (10-bit/HDR HEIF, tone mapped there by Core
/// Image), camera RAW (PhotoKit renders RAW its own way), and anything ImageIO cannot read.
func downsampledPhotoLibraryImage(data: Data, maxSize: CGSize, resize: (UIImage, CGSize) -> UIImage?) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
        return nil
    }
    if let type = CGImageSourceGetType(source) as String?, let utType = UTType(type), utType.conforms(to: .rawImage) {
        return nil
    }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return nil
    }
    if let depth = properties[kCGImagePropertyDepth] as? Int, depth > 8 {
        return nil
    }
    guard let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int, let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int, pixelWidth > 0, pixelHeight > 0 else {
        return nil
    }
    var orientedSize = CGSize(width: pixelWidth, height: pixelHeight)
    if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 && orientation <= 8 {
        orientedSize = CGSize(width: pixelHeight, height: pixelWidth)
    }
    let uploadSize = photoLibraryUploadSize(orientedPixelSize: orientedSize, maxSize: maxSize)
    guard uploadSize.width >= 1.0, uploadSize.height >= 1.0 else {
        return nil
    }
    // ImageIO rounds the thumbnail's other side; asking for the long side of the upload size gives
    // a thumbnail within a pixel of it, and `resize` makes it exact.
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(max(uploadSize.width, uploadSize.height))
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
        return nil
    }
    if thumbnail.bitsPerComponent > 8 {
        return nil
    }
    return resize(UIImage(cgImage: thumbnail), uploadSize)
}
