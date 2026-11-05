import Foundation
import CoreGraphics
import ImageIO

public enum ImageDecodeSizing {
    public static let minimumSavingFactor: CGFloat = 1.5

    public static func thumbnailMaxPixelSize(sourceWidth: Int, sourceHeight: Int, targetPixelSize: CGSize) -> Int? {
        guard sourceWidth > 0, sourceHeight > 0, targetPixelSize.width > 0.0, targetPixelSize.height > 0.0,
              targetPixelSize.width.isFinite, targetPixelSize.height.isFinite else {
            return nil
        }
        let scaleNeeded = max(targetPixelSize.width / CGFloat(sourceWidth), targetPixelSize.height / CGFloat(sourceHeight))
        if scaleNeeded * ImageDecodeSizing.minimumSavingFactor >= 1.0 {
            return nil
        }
        let longestSide = CGFloat(max(sourceWidth, sourceHeight))
        let value = (scaleNeeded * longestSide).rounded(.up)
        guard value >= 1.0, value < longestSide else {
            return nil
        }
        return Int(value)
    }

    public static func sourcePixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return nil
        }
        return (width, height)
    }

    public static func downscaledImage(source: CGImageSource, targetPixelSize: CGSize) -> CGImage? {
        guard let size = ImageDecodeSizing.sourcePixelSize(source),
              let maxPixelSize = ImageDecodeSizing.thumbnailMaxPixelSize(sourceWidth: size.width, sourceHeight: size.height, targetPixelSize: targetPixelSize) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
