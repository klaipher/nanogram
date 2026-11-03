import Foundation
import UIKit
import Display
#if canImport(VisionKit)
import VisionKit
#endif

/// iPad: the system's Live Text on a photo in the media viewer (VisionKit `ImageAnalysisInteraction`), beside
/// Telegram's own text-recognition button, which stays. A long press selects text in the photo (copy, look up,
/// translate, share), and links, phone numbers, dates and addresses in it become tappable. The system's floating
/// Live Text button is hidden, so nothing new is drawn over the photo or the viewer's footer.
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
            interaction.preferredInteractionTypes = [.textSelection, .dataDetectors]
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
