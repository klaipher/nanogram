import Foundation
import UIKit
import XCTest
import MultiAnimationRenderer
@testable import EmojiTextAttachmentView

// The reaction button's hand-off waits for its InlineStickerItemLayer to show something real. The
// layer first shows the sticker's silhouette (an outline drawn from the thumbnail data) while the
// first frame loads; that placeholder must not count, or the stand-in goes and leaves an outline.
final class InlineStickerItemLayerContentTests: XCTestCase {
    private func makeImage() -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4.0, height: 4.0))
        return renderer.image(actions: { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0.0, y: 0.0, width: 4.0, height: 4.0))
        }).cgImage!
    }

    // A layer with no loading behind it (the copy initializer), so the test drives its contents.
    private func makeLayer() -> InlineStickerItemLayer {
        return InlineStickerItemLayer(layer: MultiAnimationRenderTarget())
    }

    func testThePlaceholderOutlineIsNotContent() {
        let layer = self.makeLayer()
        var displayed = 0
        layer.contentDisplayed = {
            displayed += 1
        }

        layer.setPlaceholderContents(self.makeImage())
        XCTAssertNotNil(layer.contents)
        XCTAssertFalse(layer.hasDisplayedContent, "the silhouette placeholder is not a frame")
        XCTAssertEqual(displayed, 0)

        layer.contents = self.makeImage()
        XCTAssertTrue(layer.hasDisplayedContent, "the first real frame is")
        XCTAssertEqual(displayed, 1)

        layer.contents = self.makeImage()
        XCTAssertEqual(displayed, 1, "reported once")
    }

    // The renderer gives the first frame to a layer that has none when its item's frames arrive;
    // the silhouette placeholder does not count as one.
    func testALayerShowingOnlyThePlaceholderNeedsAFrame() {
        let layer = self.makeLayer()
        XCTAssertTrue(layer.needsFrame)
        layer.setPlaceholderContents(self.makeImage())
        XCTAssertTrue(layer.needsFrame, "the silhouette placeholder is not a frame")
        layer.contents = self.makeImage()
        XCTAssertFalse(layer.needsFrame)
    }

    func testClearingContentsIsNotContent() {
        let layer = self.makeLayer()
        layer.contents = nil
        XCTAssertFalse(layer.hasDisplayedContent)
    }

    // A placeholder drawn off the main thread lands only if nothing newer happened to the layer.
    func testADeferredPlaceholderLandsOnlyWhileItIsCurrentAndNoFrameShowed() {
        let layer = self.makeLayer()
        let generation = layer.beginPlaceholderGeneration()
        XCTAssertTrue(layer.applyDeferredPlaceholder(self.makeImage(), generation: generation))
        XCTAssertNotNil(layer.contents)
        XCTAssertFalse(layer.hasDisplayedContent)

        let reloaded = self.makeLayer()
        let stale = reloaded.beginPlaceholderGeneration()
        let _ = reloaded.beginPlaceholderGeneration()
        XCTAssertFalse(reloaded.applyDeferredPlaceholder(self.makeImage(), generation: stale), "the item was reloaded")
        XCTAssertNil(reloaded.contents)

        let shown = self.makeLayer()
        let current = shown.beginPlaceholderGeneration()
        shown.contents = self.makeImage()
        XCTAssertFalse(shown.applyDeferredPlaceholder(self.makeImage(), generation: current), "the real frame came first")
    }
}
