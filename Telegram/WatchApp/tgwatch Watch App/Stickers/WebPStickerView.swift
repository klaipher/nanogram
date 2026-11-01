import ImageIO
import SwiftUI
import UIKit
import WatchKit
import WebPKit

/// Static-image sticker (WEBP). watchOS lacks a native WebP codec in ImageIO,
/// so we use the vendored libwebp via WebPKit. Falls back to the raster thumbnail
/// (JPEG/PNG through ImageIO, WEBP through WebPKit) while the main file downloads;
/// falls back to a gray placeholder of the correct aspect ratio if neither is available.
struct WebPStickerView: View {
    let sticker: StickerVisual
    let displaySize: CGSize

    private var screenScale: CGFloat { WKInterfaceDevice.current().screenScale }

    var body: some View {
        Group {
            if let path = sticker.localPath,
               let image = MediaImageCache.image(path: path, format: .webp, maxPixelSize: maxPixelSize) {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let image = stickerThumbnail(sticker) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
    }

    /// Stickers are 512 px; the bubble shows them at 120 pt.
    private var maxPixelSize: Int {
        Int((max(displaySize.width, displaySize.height) * screenScale).rounded(.up))
    }
}

/// The sticker's raster thumbnail (JPEG/PNG/WEBP), decoded once. Nil if the format is
/// unknown, the file isn't downloaded or the decode fails.
func stickerThumbnail(_ sticker: StickerVisual) -> UIImage? {
    guard let path = sticker.thumbnailLocalPath else { return nil }
    switch sticker.thumbnailFormat {
    case .webp:
        return MediaImageCache.image(path: path, format: .webp)
    case .jpeg, .png:
        return MediaImageCache.image(path: path, format: .native)
    case .unsupported, nil:
        return nil
    }
}

/// Decoded chat images (stickers, thumbnails, photo and video previews), keyed by file
/// path and pixel size. The message list re-evaluates every row whenever the store's rows
/// change (each download progress update of a visible file does that), so a bubble that
/// decoded its file in `body` read and decoded it again every time; with the cache it
/// decodes once. Thread-safe (NSCache); entries are dropped under memory pressure and
/// beyond `costLimit` bytes of pixels.
enum MediaImageCache {
    enum Format {
        /// WebP through WebPKit (watchOS ImageIO has no WebP codec).
        case webp
        /// JPEG/PNG through ImageIO.
        case native
    }

    static let costLimit = 16 * 1024 * 1024

    // NSCache is thread-safe; no actor isolation needed.
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = costLimit
        return cache
    }()

    /// The image at `path`, decoded and, when `maxPixelSize` is given, scaled down so its
    /// longer side is at most that many pixels (never up). Nil if the file can't be decoded.
    static func image(path: String, format: Format, maxPixelSize: Int? = nil) -> UIImage? {
        let key = cacheKey(path: path, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = decode(path: path, format: format, maxPixelSize: maxPixelSize) else { return nil }
        cache.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    /// Caches an image produced elsewhere (a rendered lottie frame) under `key`.
    static func image(key: String, make: () -> UIImage?) -> UIImage? {
        let nsKey = key as NSString
        if let cached = cache.object(forKey: nsKey) { return cached }
        guard let image = make() else { return nil }
        cache.setObject(image, forKey: nsKey, cost: cost(of: image))
        return image
    }

    static func removeAll() { cache.removeAllObjects() }

    /// Uncached decode.
    static func decode(path: String, format: Format, maxPixelSize: Int?) -> UIImage? {
        switch format {
        case .webp:
            guard let full = WebPDecoder.decode(url: URL(fileURLWithPath: path)) else { return nil }
            guard let maxPixelSize else { return UIImage(cgImage: full) }
            return UIImage(cgImage: scaledDown(full, maxPixelSize: maxPixelSize) ?? full)
        case .native:
            guard let maxPixelSize else { return UIImage(contentsOfFile: path) }
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
    }

    /// `image` redrawn so its longer side is `maxPixelSize`, or nil if it is already no larger.
    static func scaledDown(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longer = max(image.width, image.height)
        guard maxPixelSize > 0, longer > maxPixelSize else { return nil }
        let ratio = CGFloat(maxPixelSize) / CGFloat(longer)
        let width = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let height = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func cacheKey(path: String, maxPixelSize: Int?) -> NSString {
        "\(path)|\(maxPixelSize.map(String.init) ?? "full")" as NSString
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}
