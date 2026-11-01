import Foundation
import UIKit

/// Rendered (decoded, scaled and clipped) avatars, keyed by everything the render depends on.
/// On device each miss decodes a JPEG through the hardware decoder, which costs about 4 ms of CPU
/// for a small avatar, mostly IPC. Bounded by cost; emptied on memory warning and in background.
final class PeerAvatarImageCache {
    static let shared = PeerAvatarImageCache(totalCostLimit: 8 * 1024 * 1024)

    /// Bigger renders (profile headers) are rare and would push out many list avatars.
    static let maximumEntryCost = 1024 * 1024

    private final class Entry {
        let rounded: UIImage
        let unrounded: UIImage

        init(rounded: UIImage, unrounded: UIImage) {
            self.rounded = rounded
            self.unrounded = unrounded
        }
    }

    private let cache = NSCache<NSString, Entry>()
    private var observers: [NSObjectProtocol] = []

    init(totalCostLimit: Int) {
        self.cache.totalCostLimit = totalCostLimit
        let cache = self.cache
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil, using: { _ in
                cache.removeAllObjects()
            }))
        }
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static func key(resourceId: String, dataLength: Int, displayDimensions: CGSize, clipStyle: AvatarNodeClipStyle, blurred: Bool, inset: CGFloat, provideUnrounded: Bool, cutoutRect: CGRect?) -> NSString {
        let cutout: String
        if let cutoutRect {
            cutout = "\(cutoutRect.origin.x),\(cutoutRect.origin.y),\(cutoutRect.width),\(cutoutRect.height)"
        } else {
            cutout = "-"
        }
        return "\(resourceId)|\(dataLength)|\(displayDimensions.width)x\(displayDimensions.height)|\(clipStyle)|\(blurred)|\(inset)|\(provideUnrounded)|\(cutout)" as NSString
    }

    func get(_ key: NSString) -> (UIImage, UIImage)? {
        if let entry = self.cache.object(forKey: key) {
            return (entry.rounded, entry.unrounded)
        }
        return nil
    }

    func set(_ key: NSString, rounded: UIImage, unrounded: UIImage) {
        var cost = PeerAvatarImageCache.cost(rounded)
        if unrounded !== rounded {
            cost += PeerAvatarImageCache.cost(unrounded)
        }
        if cost > PeerAvatarImageCache.maximumEntryCost {
            return
        }
        self.cache.setObject(Entry(rounded: rounded, unrounded: unrounded), forKey: key, cost: cost)
    }

    private static func cost(_ image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        // Unknown size: too big to keep.
        return PeerAvatarImageCache.maximumEntryCost + 1
    }
}
