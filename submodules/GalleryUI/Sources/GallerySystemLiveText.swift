import Foundation
import UIKit
import Display
#if canImport(VisionKit)
import VisionKit
#endif

/// iPad: the system's Live Text on a photo in the media viewer (VisionKit `ImageAnalysisInteraction`), beside
/// Telegram's own text-recognition button, which stays. Nothing is drawn over the photo until the user asks: the
/// interaction only does text selection, so a long press on text selects it (copy, look up, translate, share), and no
/// underline or highlight appears when the photo opens. Data detectors (dates, times, links, phone numbers) are left
/// off because VisionKit underlines them the moment the analysis arrives; `galleryLiveTextInteractionTypes` turns them
/// on only for a user's request. The system's floating Live Text button is hidden too.
///
/// Text selection needs a ready analysis to work on a long press, so the photo is still analysed in the background
/// after the dwell below (an analysis is invisible); nothing waits for a tap.
/// Tablet only, iOS 16+, where VisionKit's analyzer runs, never on copy-protected or secret media, not while the
/// "Disable Image Content Analysis" Debug switch or Power Saving is on (`galleryAnalyzesSystemLiveText`).
///
/// When it attaches and analyses is `GalleryLiveTextScheduler` (Display): the interaction is added on the main thread,
/// once per photo, and the photo is analysed once, after it has stayed the current page for half a second.
final class GallerySystemLiveText {
    private let scheduler = GalleryLiveTextScheduler()
    private var interaction: AnyObject?
    private weak var view: UIView?
    private var task: Task<Void, Never>?

    init() {
        self.scheduler.attach = { [weak self] in
            self?.attachInteraction()
        }
        self.scheduler.analyze = { [weak self] makeImage in
            self?.analyze(makeImage: makeImage)
        }
        self.scheduler.detach = { [weak self] in
            self?.detachInteraction()
        }
    }

    deinit {
        self.task?.cancel()
    }

    /// A medium- or full-quality image of the photo is ready; `makeImage` draws it at most 1280 px on its longer side.
    /// Any thread. `target` runs on the main thread and returns the view showing the whole image in its bounds and
    /// the conditions, or nil when the node is gone.
    func imageReady(makeImage: @escaping () -> UIImage?, target: @escaping () -> (view: UIView, conditions: GalleryLiveTextConditions)?) {
        #if canImport(VisionKit)
        guard #available(iOS 16.0, *) else {
            return
        }
        self.scheduler.imageReady(makeImage: makeImage, conditions: { [weak self] in
            guard let self, let target = target() else {
                return nil
            }
            var conditions = target.conditions
            conditions.isSupported = ImageAnalyzer.isSupported
            if self.interaction == nil {
                self.view = target.view
            }
            return conditions
        })
        #endif
    }

    /// The photo became, or stopped being, the gallery's current page. Main thread.
    func centralityUpdated(isCentral: Bool) {
        self.scheduler.centralityUpdated(isCentral: isCentral)
    }

    /// The node now shows another photo. Main thread.
    func reset() {
        self.scheduler.reset()
    }

    private func attachInteraction() {
        #if canImport(VisionKit)
        guard #available(iOS 16.0, *), let view = self.view else {
            return
        }
        // The scheduler calls this on the main thread only.
        let interaction = MainActor.assumeIsolated {
            let interaction = ImageAnalysisInteraction()
            var types: ImageAnalysisInteraction.InteractionTypes = []
            let wanted = galleryLiveTextInteractionTypes(userRequestedRecognition: false)
            if wanted.contains(.textSelection) {
                types.insert(.textSelection)
            }
            if wanted.contains(.dataDetectors) {
                types.insert(.dataDetectors)
            }
            interaction.preferredInteractionTypes = types
            interaction.selectableItemsHighlighted = false
            interaction.isSupplementaryInterfaceHidden = true
            view.addInteraction(interaction)
            return interaction
        }
        self.interaction = interaction
        #endif
    }

    private func analyze(makeImage: @escaping () -> UIImage?) {
        #if canImport(VisionKit)
        guard #available(iOS 16.0, *), let interaction = self.interaction as? ImageAnalysisInteraction else {
            return
        }
        self.task?.cancel()
        self.task = Task { @MainActor [weak interaction] in
            // Drawn off the main thread, at most 1280 px on its longer side (the caller's size).
            let image = await Task.detached(priority: .utility) {
                return makeImage()
            }.value
            guard let image, !Task.isCancelled else {
                return
            }
            let analyzer = ImageAnalyzer()
            let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            guard let analysis = try? await analyzer.analyze(image, configuration: configuration), !Task.isCancelled else {
                return
            }
            interaction?.analysis = analysis
        }
        #endif
    }

    private func detachInteraction() {
        self.task?.cancel()
        self.task = nil
        #if canImport(VisionKit)
        if #available(iOS 16.0, *), let interaction = self.interaction as? ImageAnalysisInteraction {
            let view = self.view
            // The scheduler calls this on the main thread only.
            MainActor.assumeIsolated {
                interaction.analysis = nil
                view?.removeInteraction(interaction)
            }
        }
        #endif
        self.interaction = nil
        self.view = nil
    }
}
