import Foundation
import SwiftSignalKit
import Display
import UIKit

/// Signpost names for the steps of opening the emoji / sticker / GIF panel (category `Performance`, see docs/profiling.md).
/// One Performance Trace of the open shows where the wall time goes, including the time the main thread spends
/// blocked (the 231 ms hang was only 28 % on-CPU). Intervals nest in this order:
///
/// `emojiPanelOpenToReady` (tap until the first run-loop turn after the panel's first layout) contains
/// `emojiPanelInputNodeForState` > `emojiPanelInputNodeInit`, `chatInputNodeUpdateLayout` > `emojiPanelEntityKeyboardUpdate`
/// > `emojiPanelGifLayerCreate` (per tile), `emojiPanelReloadInputViews`, `emojiPanelEnsureFocused` and
/// `emojiPanelKeyboardDismiss` (the first-responder / keyboard steps).
public enum EmojiPanelOpenSignpost {
    public static let openToReady: StaticString = "emojiPanelOpenToReady"
    public static let inputNodeForState: StaticString = "emojiPanelInputNodeForState"
    public static let inputNodeInit: StaticString = "emojiPanelInputNodeInit"
    public static let inputNodeUpdateLayout: StaticString = "chatInputNodeUpdateLayout"
    public static let entityKeyboardUpdate: StaticString = "emojiPanelEntityKeyboardUpdate"
    public static let gifLayerCreate: StaticString = "emojiPanelGifLayerCreate"
    public static let reloadInputViews: StaticString = "emojiPanelReloadInputViews"
    public static let ensureFocused: StaticString = "emojiPanelEnsureFocused"
    public static let keyboardDismiss: StaticString = "emojiPanelKeyboardDismiss"
    public static let deferredKeyboardHandoff: StaticString = "emojiPanelDeferredKeyboardHandoff"
    public static let deferredGifTiles: StaticString = "emojiPanelDeferredGifTiles"
    public static let firstTurnAfterLayout: StaticString = "emojiPanelFirstTurnAfterLayout"

    // Main thread only.
    nonisolated(unsafe) private static var openShot: PerformanceSignposts.OneShot?
    nonisolated(unsafe) private static var openGeneration: Int = 0

    public static let danglingOpenTimeout: Double = 2.0

    /// The panel was requested (tap on the panel button). A second request closes the first interval, and an interval
    /// that no layout ever ends is closed after `danglingOpenTimeout`.
    public static func beginOpen() {
        self.openShot?.end()
        self.openShot = PerformanceSignposts.OneShot(self.openToReady)
        self.openGeneration += 1
        let generation = self.openGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + self.danglingOpenTimeout) {
            if self.openGeneration == generation {
                self.endOpen()
            }
        }
    }

    public static var isOpenIntervalActive: Bool {
        return self.openShot != nil
    }

    /// The first run-loop turn after the panel's first layout. A proxy for "first render": the exact commit time is in the
    /// Hitches / Animation Hitches lanes of the same trace.
    public static func endOpen() {
        if self.openShot != nil {
            PerformanceSignposts.event(self.firstTurnAfterLayout)
        }
        self.openShot?.end()
        self.openShot = nil
    }
}

/// Runs a block on a later main-thread turn, after the frame that is being prepared now has been committed.
/// `Queue.mainQueue().async` is not enough for that: it runs the block inline when already on the main queue.
/// A one-shot display link fires at the next frame start; the short timer is the fallback when no frames are produced.
public final class NextFrame: NSObject {
    public static let fallbackDelay: Double = 0.05

    private var block: (() -> Void)?
    private var displayLink: CADisplayLink?

    private init(block: @escaping () -> Void) {
        self.block = block
        super.init()
    }

    @discardableResult
    public static func run(_ block: @escaping () -> Void) -> NextFrame {
        let task = NextFrame(block: block)
        let displayLink = CADisplayLink(target: task, selector: #selector(NextFrame.tick))
        task.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + self.fallbackDelay) {
            task.fire()
        }
        return task
    }

    public func cancel() {
        self.block = nil
        self.finish()
    }

    @objc private func tick() {
        self.fire()
    }

    private func fire() {
        let block = self.block
        self.block = nil
        self.finish()
        block?()
    }

    private func finish() {
        self.displayLink?.invalidate()
        self.displayLink = nil
    }
}

/// Debug Settings switch "Emoji panel: defer first-responder handoff / heavy layers" (off by default, main app only).
/// Cached `Bool`, written on the main thread when the experimental settings change (`SharedAccountContext`), read on the
/// main thread. With it off, nothing in the panel open path differs from before.
public enum EmojiPanelOpenTuning {
    nonisolated(unsafe) private static var defersHeavyWorkValue = false

    public static var defersHeavyWork: Bool {
        return self.defersHeavyWorkValue
    }

    public static func setDefersHeavyWork(_ value: Bool) {
        self.defersHeavyWorkValue = value
    }
}

/// Mitigation 1: the keyboard / first-responder handoff for the media input mode runs after the panel has been built.
public struct DeferredKeyboardHandoffGate {
    private var token: Int = 0
    public private(set) var isPending: Bool = false

    public init() {
    }

    /// Whether the handoff is deferred for a state change. Only when switching into the media mode while the panel does not
    /// exist yet (the synchronous build is what is being moved ahead of the handoff).
    public static func shouldDefer(switchEnabled: Bool, wasMedia: Bool, willBeMedia: Bool, panelAlreadyBuilt: Bool, hasCustomTextView: Bool) -> Bool {
        return switchEnabled && willBeMedia && !wasMedia && !panelAlreadyBuilt && !hasCustomTextView
    }

    /// Starts a deferred handoff; a handoff scheduled earlier becomes stale.
    public mutating func schedule() -> Int {
        self.token += 1
        self.isPending = true
        return self.token
    }

    /// A state change that makes the pending handoff obsolete (the mode left media, the node went away).
    public mutating func cancel() {
        self.token += 1
        self.isPending = false
    }

    /// True once for the newest scheduled token.
    public mutating func consume(_ token: Int) -> Bool {
        guard self.isPending, token == self.token else {
            return false
        }
        self.isPending = false
        return true
    }
}

/// Mitigation 2: GIF tiles (each owns an `AVSampleBufferDisplayLayer`) are created for visible tiles only after the pane is
/// on screen, a few per run-loop turn.
public enum LazyGifTilePlan {
    /// Tiles created in one pass; the rest follow on the next run-loop turn.
    public static let tilesPerPass = 6

    public static func mayCreateTile(switchEnabled: Bool, paneSettled: Bool, createdInThisPass: Int) -> Bool {
        if !switchEnabled {
            return true
        }
        return paneSettled && createdInThisPass < self.tilesPerPass
    }
}
