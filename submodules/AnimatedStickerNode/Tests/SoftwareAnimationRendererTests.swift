import Foundation
import UIKit
import XCTest
import Accelerate
import SwiftSignalKit
import AsyncDisplayKit
import Display
@testable import AnimatedStickerNode

// Straight-alpha BGRA with soft edges, as the video sticker path delivers it (multiplyAlpha).
private func makeStraightBgraFrame(width: Int, height: Int, bytesPerRow: Int) -> Data {
    var data = Data(count: bytesPerRow * height)
    data.withUnsafeMutableBytes { bytes in
        let pixels = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let p = pixels.advanced(by: y * bytesPerRow + x * 4)
                p[0] = UInt8(truncatingIfNeeded: x * 7 + y)
                p[1] = UInt8(truncatingIfNeeded: y * 5 + 31)
                p[2] = UInt8(truncatingIfNeeded: x * 3 + y * 2 + 90)
                let dx = x - width / 2, dy = y - height / 2
                p[3] = UInt8(clamping: max(0, 255 - (dx * dx + dy * dy) / 3))
            }
        }
    }
    return data
}

private func bytes(of image: CGImage) -> [UInt8] {
    let width = image.width, height = image.height
    var result = [UInt8](repeating: 0, count: width * height * 4)
    result.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return result
}

// What the layer tree shows, rendered offscreen.
private func renderLayer(_ layer: CALayer, size: CGSize) -> [UInt8] {
    let width = Int(size.width), height = Int(size.height)
    var result = [UInt8](repeating: 0, count: width * height * 4)
    result.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: DeviceGraphicsContextSettings.shared.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        layer.render(in: context)
    }
    return result
}

// One window for the whole run: in a logic test (no host app) a released window invalidates its
// scene, which traps in BackBoardServices during a later run loop turn.
private let sharedTestWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))

final class SoftwareAnimationRendererTests: XCTestCase {
    private let queue = Queue(name: "SoftwareAnimationRendererTests")
    private let width = 96
    private let height = 80

    private func render(_ renderer: SoftwareAnimationRenderer, data: Data, type: AnimationRendererFrameType, mulAlpha: Bool, bytesPerRow: Int) {
        var completed = false
        renderer.render(queue: self.queue, width: self.width, height: self.height, bytesPerRow: bytesPerRow, data: data, type: type, mulAlpha: mulAlpha, completion: {
            completed = true
        }, averageColor: nil)
        let deadline = Date().addingTimeInterval(10.0)
        while !completed && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(completed)
    }

    private func makeRenderer() -> SoftwareAnimationRenderer {
        let renderer = SoftwareAnimationRenderer(templateImageSupport: true)
        renderer.frame = CGRect(x: 0, y: 0, width: 48, height: 40)
        renderer.view.layoutIfNeeded()
        return renderer
    }

    // The multiplied frame equals permute + premultiply ARGB + permute of the source.
    func testArgbFrameIsPremultipliedExactly() throws {
        let bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: self.width)
        let source = makeStraightBgraFrame(width: self.width, height: self.height, bytesPerRow: bytesPerRow)
        var expected = source
        expected.withUnsafeMutableBytes { bytes in
            var buffer = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(self.height), width: vImagePixelCount(self.width), rowBytes: bytesPerRow)
            let permuteMap: [UInt8] = [3, 2, 1, 0]
            vImagePermuteChannels_ARGB8888(&buffer, &buffer, permuteMap, vImage_Flags(kvImageDoNotTile))
            vImagePremultiplyData_ARGB8888(&buffer, &buffer, vImage_Flags(kvImageDoNotTile))
            vImagePermuteChannels_ARGB8888(&buffer, &buffer, permuteMap, vImage_Flags(kvImageDoNotTile))
        }

        let renderer = self.makeRenderer()
        self.render(renderer, data: source, type: .argb, mulAlpha: true, bytesPerRow: bytesPerRow)
        let cgImage = try XCTUnwrap(renderer.currentFrameImage?.cgImage)
        let provided = try XCTUnwrap(cgImage.dataProvider?.data as Data?)
        var differences = 0
        for y in 0 ..< self.height {
            for x in 0 ..< self.width * 4 where provided[y * cgImage.bytesPerRow + x] != expected[y * bytesPerRow + x] {
                differences += 1
            }
        }
        XCTAssertEqual(differences, 0)
    }

    // Without a tint the frame goes straight into the layer, and looks exactly like the image view did.
    func testUntintedFrameLooksLikeTheImageView() throws {
        let bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: self.width)
        let source = makeStraightBgraFrame(width: self.width, height: self.height, bytesPerRow: bytesPerRow)
        let renderer = self.makeRenderer()
        self.render(renderer, data: source, type: .argb, mulAlpha: true, bytesPerRow: bytesPerRow)
        let image = try XCTUnwrap(renderer.currentFrameImage)

        let imageView = try XCTUnwrap(renderer.view as? UIImageView)
        XCTAssertNil(imageView.image)
        XCTAssertTrue((renderer.layer.contents as AnyObject?) === image.cgImage)

        let reference = UIImageView(frame: renderer.bounds)
        reference.image = image
        reference.layoutIfNeeded()

        let size = CGSize(width: 48, height: 40)
        let actual = renderLayer(renderer.layer, size: size)
        let expected = renderLayer(reference.layer, size: size)
        XCTAssertGreaterThan(expected.filter { $0 != 0 }.count, 1000, "the reference must show something")
        XCTAssertEqual(actual, expected)
    }

    // A template (tinted) frame still uses the image view, and turning the tint off goes back to the layer.
    func testTemplateFramesUseTheImageView() throws {
        let bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: self.width)
        let source = makeStraightBgraFrame(width: self.width, height: self.height, bytesPerRow: bytesPerRow)
        let renderer = self.makeRenderer()
        let imageView = try XCTUnwrap(renderer.view as? UIImageView)

        self.render(renderer, data: source, type: .argb, mulAlpha: true, bytesPerRow: bytesPerRow)
        XCTAssertNil(imageView.image)

        renderer.renderAsTemplateImage = true
        imageView.tintColor = .red
        self.render(renderer, data: source, type: .argb, mulAlpha: true, bytesPerRow: bytesPerRow)
        XCTAssertEqual(imageView.image?.renderingMode, .alwaysTemplate)
        XCTAssertTrue(imageView.image === renderer.currentFrameImage)

        renderer.renderAsTemplateImage = false
        imageView.tintColor = nil
        self.render(renderer, data: source, type: .argb, mulAlpha: true, bytesPerRow: bytesPerRow)
        XCTAssertNil(imageView.image)
        XCTAssertTrue((renderer.layer.contents as AnyObject?) === renderer.currentFrameImage?.cgImage)
    }

    // UIKit re-applies an image view's image on window moves, trait and tint changes; a frame put
    // into the layer directly must survive them (a paused sticker gets no new frame).
    func testFrameSurvivesWindowAndTraitChanges() throws {
        let bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: self.width)
        let source = makeStraightBgraFrame(width: self.width, height: self.height, bytesPerRow: bytesPerRow)
        let renderer = self.makeRenderer()
        self.render(renderer, data: source, type: .argb, mulAlpha: true, bytesPerRow: bytesPerRow)
        let cgImage = try XCTUnwrap(renderer.currentFrameImage?.cgImage)

        let window = sharedTestWindow
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        container.addSubview(renderer.view)
        renderer.view.layoutIfNeeded()
        XCTAssertTrue((renderer.layer.contents as AnyObject?) === cgImage, "after moving to a window")

        window.overrideUserInterfaceStyle = .dark
        container.setNeedsLayout()
        container.layoutIfNeeded()
        renderer.view.traitCollectionDidChange(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue((renderer.layer.contents as AnyObject?) === cgImage, "after a trait change")

        renderer.view.tintColor = .green
        renderer.view.setNeedsLayout()
        renderer.view.layoutIfNeeded()
        XCTAssertTrue((renderer.layer.contents as AnyObject?) === cgImage, "after a tint change")

        renderer.view.removeFromSuperview()
        container.addSubview(renderer.view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue((renderer.layer.contents as AnyObject?) === cgImage, "after moving between views")
        renderer.view.removeFromSuperview()
        container.removeFromSuperview()
    }

    // UIKit clears an image view's layer contents when the view changes size and has no image, so a
    // frame put into the layer directly was lost on a resize: a still, paused or finished sticker
    // (a reaction's still frame, a cloned frame) stayed empty until a next frame that never came.
    func testFrameSurvivesResize() throws {
        let bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: self.width)
        let source = makeStraightBgraFrame(width: self.width, height: self.height, bytesPerRow: bytesPerRow)
        let renderer = self.makeRenderer()
        self.render(renderer, data: source, type: .argb, mulAlpha: true, bytesPerRow: bytesPerRow)
        let cgImage = try XCTUnwrap(renderer.currentFrameImage?.cgImage)

        renderer.frame = CGRect(x: 0, y: 0, width: 96, height: 80)
        renderer.view.layoutIfNeeded()
        XCTAssertTrue((renderer.layer.contents as AnyObject?) === cgImage, "after a frame resize")

        renderer.bounds = CGRect(x: 0, y: 0, width: 60, height: 50)
        renderer.view.layoutIfNeeded()
        XCTAssertTrue((renderer.layer.contents as AnyObject?) === cgImage, "after a bounds resize")

        renderer.view.frame = CGRect(x: 0, y: 0, width: 48, height: 40)
        renderer.view.layoutIfNeeded()
        XCTAssertTrue((renderer.layer.contents as AnyObject?) === cgImage, "after a view resize")
    }

    // A frame copied from another node (cloneCurrentFrame) before the renderer gets its size.
    func testClonedFrameSurvivesTheFirstSize() throws {
        let bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: self.width)
        let source = makeStraightBgraFrame(width: self.width, height: self.height, bytesPerRow: bytesPerRow)
        let other = self.makeRenderer()
        self.render(other, data: source, type: .argb, mulAlpha: true, bytesPerRow: bytesPerRow)
        let cgImage = try XCTUnwrap(other.currentFrameImage?.cgImage)

        let renderer = SoftwareAnimationRenderer(templateImageSupport: true)
        let _ = renderer.view
        renderer.contents = other.contents
        renderer.frame = CGRect(x: 0, y: 0, width: 48, height: 40)
        renderer.view.layoutIfNeeded()
        XCTAssertTrue((renderer.layer.contents as AnyObject?) === cgImage)
    }

    // An overlay that replaces the content hides the frame, in either display mode.
    func testReplacingOverlayHidesTheFrame() throws {
        let bytesPerRow = DeviceGraphicsContextSettings.shared.bytesPerRow(forWidth: self.width)
        let source = makeStraightBgraFrame(width: self.width, height: self.height, bytesPerRow: bytesPerRow)
        let renderer = self.makeRenderer()
        let imageView = try XCTUnwrap(renderer.view as? UIImageView)

        self.render(renderer, data: source, type: .argb, mulAlpha: true, bytesPerRow: bytesPerRow)
        XCTAssertNotNil(renderer.layer.contents)

        renderer.setOverlayColor(.blue, replace: true, animated: false)
        XCTAssertNil(renderer.layer.contents)
        XCTAssertNil(imageView.image)

        self.render(renderer, data: source, type: .argb, mulAlpha: true, bytesPerRow: bytesPerRow)
        XCTAssertNil(renderer.layer.contents)
        XCTAssertNil(imageView.image)

        renderer.setOverlayColor(nil, replace: false, animated: false)
        self.render(renderer, data: source, type: .argb, mulAlpha: true, bytesPerRow: bytesPerRow)
        XCTAssertTrue((renderer.layer.contents as AnyObject?) === renderer.currentFrameImage?.cgImage)
    }
}
