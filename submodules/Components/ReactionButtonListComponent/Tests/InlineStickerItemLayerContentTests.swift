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

    func testClearingContentsIsNotContent() {
        let layer = self.makeLayer()
        layer.contents = nil
        XCTAssertFalse(layer.hasDisplayedContent)
    }
}
