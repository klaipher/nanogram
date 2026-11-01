import Foundation
import SwiftSignalKit

/// Which renderer `DefaultAnimatedStickerNodeImpl` uses (Debug Settings ▸ "Stickers: renderer").
/// Each renderer comes with its own frame cache: the Metal renderer reads the DCT `-mtl` cache,
/// the CPU renderer the LZ4 YUVA cache. A node never mixes them.
public enum AnimatedStickerRendererMode: Equatable {
    /// Every node renders on the CPU (`SoftwareAnimationRenderer`), unless its creator asked for
    /// the Metal cache explicitly. Today's behaviour.
    case cpu
    /// Nodes of at least `animatedStickerLargePixelArea` pixels render with Metal.
    case gpuLarge
    /// Every node renders with Metal (`CompressedAnimationRenderer`).
    case gpuAll

    private static let current = Atomic<AnimatedStickerRendererMode>(value: .cpu)

    /// The process-wide mode. Nodes read it once, when they are created, so a change applies to
    /// nodes created afterwards (reopen a chat to see it).
    public static var processWide: AnimatedStickerRendererMode {
        get {
            return self.current.with { $0 }
        }
        set {
            let _ = self.current.swap(newValue)
        }
    }
}

/// The smallest frame, in pixels, that `.gpuLarge` renders with Metal: 200x200.
///
/// Chat stickers are set up at 384 pixels on their long side (`ChatMessageAnimatedStickerItemNode`),
/// so even a 2.4:1 one (384x160 = 61,440) counts, and the full-screen preview fits 400x400. Sticker
/// panel and pack grids use 160x160 (25,600) and emoji and reactions are smaller still, so the many
/// small items on screen at once stay on the CPU, where a small image costs less than a Metal
/// texture upload and a GPU wake per frame.
let animatedStickerLargePixelArea = 200 * 200

/// Whether a sticker node uses the Metal renderer and its DCT frame cache.
///
/// - Parameters:
///   - mode: the node's renderer mode.
///   - explicitlyRequested: the node was created with `useMetalCache: true`; it then always uses Metal.
///   - width: the frame width in pixels, nil while the node has not been set up.
///   - height: the frame height in pixels, nil while the node has not been set up.
/// - Returns: nil when the answer depends on a size that is not known yet.
func animatedStickerUsesMetalRenderer(mode: AnimatedStickerRendererMode, explicitlyRequested: Bool, width: Int?, height: Int?) -> Bool? {
    if explicitlyRequested {
        return true
    }
    switch mode {
    case .cpu:
        return false
    case .gpuAll:
        return true
    case .gpuLarge:
        guard let width, let height else {
            return nil
        }
        return width * height >= animatedStickerLargePixelArea
    }
}
