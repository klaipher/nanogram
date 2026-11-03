import Foundation
import UIKit
import SwiftSignalKit
import Display
import AnimationCache

public protocol MultiAnimationRenderer: AnyObject {
    func add(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, unique: Bool, size: CGSize, fetch: @escaping (AnimationCacheFetchOptions) -> Disposable) -> Disposable
    func loadFirstFrameSynchronously(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize) -> Bool
    func loadFirstFrame(target: MultiAnimationRenderTarget, cache: AnimationCache, itemId: String, size: CGSize, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (Bool, Bool) -> Void) -> Disposable
    func loadFirstFrameAsImage(cache: AnimationCache, itemId: String, size: CGSize, fetch: ((AnimationCacheFetchOptions) -> Disposable)?, completion: @escaping (CGImage?) -> Void) -> Disposable
    func setFrameIndex(itemId: String, size: CGSize, frameIndex: Int, placeholder: UIImage)
}

private var nextRenderTargetId: Int64 = 1

open class MultiAnimationRenderTarget: SimpleLayer {
    public let id: Int64
    public var numFrames: Int?

    public let deinitCallbacks = Bag<() -> Void>()
    public let updateStateCallbacks = Bag<() -> Void>()

    public final var shouldBeAnimating: Bool = false {
        didSet {
            if self.shouldBeAnimating != oldValue {
                for f in self.updateStateCallbacks.copyItems() {
                    f()
                }
            }
        }
    }

    // Set while the layer draws only the alpha of its contents, in a tint colour (a template emoji:
    // contentsSwizzle "AAAA" with contentsMultiplyColor). Under that swizzle Core Animation reads alpha
    // as 1 from a YUVA surface, so the whole frame became a square of the tint colour; renderers give
    // such a target images instead. Changes are reported through updateStateCallbacks.
    public final var contentsAlphaIsMask: Bool = false {
        didSet {
            if self.contentsAlphaIsMask != oldValue {
                for f in self.updateStateCallbacks.copyItems() {
                    f()
                }
            }
        }
    }

    public var blurredRepresentationBackgroundColor: UIColor?
    public var blurredRepresentationTarget: CALayer? {
        didSet {
            if self.blurredRepresentationTarget !== oldValue {
                for f in self.updateStateCallbacks.copyItems() {
                    f()
                }
            }
        }
    }

    public override init() {
        assert(Thread.isMainThread)

        self.id = nextRenderTargetId
        nextRenderTargetId += 1

        super.init()
    }

    public override init(layer: Any) {
        guard let layer = layer as? MultiAnimationRenderTarget else {
            preconditionFailure()
        }

        self.id = layer.id

        super.init(layer: layer)
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for f in self.deinitCallbacks.copyItems() {
            f()
        }
    }

    /// Whether the target has no frame to show yet. A renderer whose item becomes ready while it
    /// does not play gives such a target the item's first frame, once: nothing else would draw one.
    /// A target that shows a placeholder of its own overrides this, since a placeholder is not a frame.
    open var needsFrame: Bool {
        return self.contents == nil
    }

    open func updateDisplayPlaceholder(displayPlaceholder: Bool) {
    }

    open func transitionToContents(_ contents: AnyObject, didLoop: Bool) {
    }
}
