import Foundation
import UIKit
import SwiftSignalKit

// A-16 (iPadOS 27 audit, 2026-11-03), review fixes C1 and I3: when the system Live Text of a gallery photo is attached
// and when its photo is analysed. The VisionKit side is `GalleryUI/Sources/GallerySystemLiveText.swift`.

/// What decides whether a gallery photo gets the system Live Text. Read on the main thread.
public struct GalleryLiveTextConditions: Equatable {
    public var deviceType: DeviceType
    /// VisionKit's `ImageAnalyzer.isSupported`.
    public var isSupported: Bool
    /// Copy-protected chat or secret media.
    public var isContentProtected: Bool
    /// Debug Settings ▸ "Disable Image Content Analysis", which also turns off Telegram's own recognition.
    public var isAnalysisDisabled: Bool
    /// Power Saving is on (by the battery, the user's "Always", or on iPad the system's signals).
    public var isPowerSaving: Bool

    public init(deviceType: DeviceType, isSupported: Bool, isContentProtected: Bool, isAnalysisDisabled: Bool, isPowerSaving: Bool) {
        self.deviceType = deviceType
        self.isSupported = isSupported
        self.isContentProtected = isContentProtected
        self.isAnalysisDisabled = isAnalysisDisabled
        self.isPowerSaving = isPowerSaving
    }
}

/// Whether a gallery photo gets the system Live Text: `galleryUsesSystemLiveText` (iPad, VisionKit supported, not
/// protected), and not while the Debug switch turns image analysis off or Power Saving is on.
public func galleryAnalyzesSystemLiveText(_ conditions: GalleryLiveTextConditions) -> Bool {
    guard galleryUsesSystemLiveText(deviceType: conditions.deviceType, isSupported: conditions.isSupported, isContentProtected: conditions.isContentProtected) else {
        return false
    }
    return !conditions.isAnalysisDisabled && !conditions.isPowerSaving
}

/// What the system Live Text of a gallery photo reacts to. A Display-side mirror of VisionKit's
/// `ImageAnalysisInteraction.InteractionTypes`, so the decision stays testable without VisionKit.
public struct GalleryLiveTextInteractionTypes: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A long press selects text. Draws nothing until the user presses.
    public static let textSelection = GalleryLiveTextInteractionTypes(rawValue: 1 << 0)
    /// Dates, times, links, phone numbers and addresses. VisionKit underlines them as soon as the analysis arrives.
    public static let dataDetectors = GalleryLiveTextInteractionTypes(rawValue: 1 << 1)
}

/// Nothing may be drawn over a photo until the user asks. A photo that has just opened gets text selection only (a
/// long press); data detectors, which highlight what they find at once, only after the user has asked for text
/// recognition (Telegram's text button in the viewer).
public func galleryLiveTextInteractionTypes(userRequestedRecognition: Bool) -> GalleryLiveTextInteractionTypes {
    return userRequestedRecognition ? [.textSelection, .dataDetectors] : [.textSelection]
}

/// Attaches the system Live Text to one gallery photo and starts its analysis.
///
/// - C1: the gallery reports a ready image from a background queue, and medium then full quality nearly at once.
///   `imageReady` may be called from any thread; it hops to the main thread, where the conditions (and the view) are
///   read and the interaction is attached once per photo. Everything else runs on the main thread.
/// - I3: the photo is analysed lazily, once, after it has been the gallery's current page for `dwellDelay`, with the
///   latest image. Neighbours the pager preloads are never analysed.
public final class GalleryLiveTextScheduler {
    /// How long a photo stays the current page before it is analysed.
    public static let dwellDelay: Double = 0.5

    /// Adds the interaction to the photo's view. Main thread.
    public var attach: (() -> Void)?
    /// Analyses the image the closure draws (the closure may be called off the main thread) and hands the result to
    /// the interaction. Main thread.
    public var analyze: ((@escaping () -> UIImage?) -> Void)?
    /// Removes the interaction. Main thread.
    public var detach: (() -> Void)?

    private let schedule: (Double, @escaping () -> Void) -> Disposable

    // Main thread only.
    private var isAttached = false
    private var isAnalysisStarted = false
    private var isCentral = false
    private var makeImage: (() -> UIImage?)?
    private var dwellTimer: Disposable?

    public init(schedule: @escaping (Double, @escaping () -> Void) -> Disposable = GalleryLiveTextScheduler.mainQueueTimer) {
        self.schedule = schedule
    }

    deinit {
        self.dwellTimer?.dispose()
    }

    public static func mainQueueTimer(delay: Double, action: @escaping () -> Void) -> Disposable {
        let timer = SwiftSignalKit.Timer(timeout: delay, repeat: false, completion: action, queue: Queue.mainQueue())
        timer.start()
        return ActionDisposable {
            timer.invalidate()
        }
    }

    /// A medium- or full-quality image of the photo is ready (`makeImage` draws it). Any thread. `conditions` is
    /// called on the main thread; nil means the photo's view is gone.
    public func imageReady(makeImage: @escaping () -> UIImage?, conditions: @escaping () -> GalleryLiveTextConditions?) {
        Queue.mainQueue().async { [weak self] in
            self?.imageReadyOnMainThread(makeImage: makeImage, conditions: conditions)
        }
    }

    private func imageReadyOnMainThread(makeImage: @escaping () -> UIImage?, conditions: () -> GalleryLiveTextConditions?) {
        if !self.isAttached {
            guard let conditions = conditions(), galleryAnalyzesSystemLiveText(conditions) else {
                return
            }
            self.isAttached = true
            self.attach?()
        }
        // A later, better image replaces the one an analysis would draw, until the analysis starts.
        self.makeImage = makeImage
        self.scheduleAnalysisIfNeeded()
    }

    /// The photo became, or stopped being, the gallery's current page. Main thread.
    public func centralityUpdated(isCentral: Bool) {
        self.isCentral = isCentral
        if isCentral {
            self.scheduleAnalysisIfNeeded()
        } else {
            self.dwellTimer?.dispose()
            self.dwellTimer = nil
        }
    }

    /// The node now shows another photo: the interaction goes, and the next image starts over. Main thread.
    public func reset() {
        self.dwellTimer?.dispose()
        self.dwellTimer = nil
        self.makeImage = nil
        self.isAnalysisStarted = false
        if self.isAttached {
            self.isAttached = false
            self.detach?()
        }
    }

    private func scheduleAnalysisIfNeeded() {
        guard self.isAttached, self.isCentral, !self.isAnalysisStarted, self.makeImage != nil, self.dwellTimer == nil else {
            return
        }
        self.dwellTimer = self.schedule(GalleryLiveTextScheduler.dwellDelay, { [weak self] in
            self?.dwellElapsed()
        })
    }

    private func dwellElapsed() {
        self.dwellTimer = nil
        guard self.isAttached, self.isCentral, !self.isAnalysisStarted, let makeImage = self.makeImage else {
            return
        }
        self.isAnalysisStarted = true
        self.analyze?(makeImage)
    }
}
