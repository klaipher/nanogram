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
/// Tablet only, iOS 16+, where VisionKit's analyzer runs, and never on copy-protected media
/// (`galleryUsesSystemLiveText`).
final class GallerySystemLiveText {
    private var interaction: AnyObject?
    private weak var view: UIView?
    private var task: Task<Void, Never>?

    deinit {
        self.task?.cancel()
    }

    /// Analyzes the image `makeImage` draws (off the main thread) and adds the interaction to `view`, which must show
    /// the whole image in its bounds. Replaces an earlier attachment.
    func attach(to view: UIView, deviceType: DeviceType, isContentProtected: Bool, makeImage: @escaping () -> UIImage?) {
        self.detach()
        #if canImport(VisionKit)
        guard #available(iOS 16.0, *) else {
            return
        }
        guard galleryUsesSystemLiveText(deviceType: deviceType, isSupported: ImageAnalyzer.isSupported, isContentProtected: isContentProtected) else {
            return
        }
        // Called on the main thread by the gallery item node (a nonisolated AsyncDisplayKit node).
        let interaction = MainActor.assumeIsolated {
            let interaction = ImageAnalysisInteraction()
            interaction.preferredInteractionTypes = [.textSelection, .dataDetectors]
            interaction.isSupplementaryInterfaceHidden = true
            view.addInteraction(interaction)
            return interaction
        }
        self.interaction = interaction
        self.view = view

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

    func detach() {
        self.task?.cancel()
        self.task = nil
        #if canImport(VisionKit)
        if #available(iOS 16.0, *), let interaction = self.interaction as? ImageAnalysisInteraction {
            let view = self.view
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
