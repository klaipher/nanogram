import XCTest
import UIKit
import AsyncDisplayKit
@testable import Display

/// ASDK rasterizes every drawn node (text, typing dots, spinners) through `ASGraphicsCreateImage`.
/// With the renderer's `.automatic` range, CoreGraphics records each drawing, inspects it and replays
/// it into a context of the format it picks (1.75 s CPU in a 10.9 min device session). These tests pin
/// the formats the nodes get, compare their pixels with the `.automatic` output and time both paths.
final class ASGraphicsRasterizationTests: XCTestCase {
    // The test host has no real screen (scale 1), so draw at a phone's 3x.
    private let scale: CGFloat = 3.0

    // MARK: - Helpers

    private func cgImage(_ contents: Any?) -> CGImage? {
        guard let contents else {
            return nil
        }
        let object = contents as AnyObject
        guard CFGetTypeID(object) == CGImage.typeID else {
            return nil
        }
        return unsafeBitCast(object, to: CGImage.self)
    }

    private func makeTextNode(_ string: NSAttributedString, width: CGFloat = 300.0, configure: ((ImmediateTextNode) -> Void)? = nil) -> ImmediateTextNode {
        let node = ImmediateTextNode()
        node.maximumNumberOfLines = 0
        node.attributedText = string
        configure?(node)
        let size = node.updateLayout(CGSize(width: width, height: 10000.0))
        node.frame = CGRect(origin: CGPoint(), size: size)
        node.displaysAsynchronously = false
        _ = node.layer
        node.setNeedsDisplayAtScale(self.scale)
        return node
    }

    /// What ASDK produced before: a fresh `.automatic` renderer per draw.
    private func automaticRendererImage(for node: TextNode, standardRange: Bool = false) -> CGImage? {
        let bounds = node.bounds
        guard let layer = node.layer as? _ASDisplayLayer else {
            return nil
        }
        let parameters = node.drawParameters(forAsyncLayer: layer)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = self.scale
        if standardRange {
            format.preferredRange = .standard
        }
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
            TextNode.draw(bounds, withParameters: parameters, isCancelled: { false }, isRasterizing: false)
        }
        return image.cgImage
    }

    /// Both images drawn into one sRGB RGBA8 buffer; returns the largest channel difference.
    private func maxChannelDifference(_ a: CGImage, _ b: CGImage) -> Int {
        let width = a.width
        let height = a.height
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            data.withUnsafeMutableBytes { buffer in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return data
        }
        let pa = pixels(a)
        let pb = pixels(b)
        var result = 0
        for i in 0 ..< pa.count {
            result = max(result, abs(Int(pa[i]) - Int(pb[i])))
        }
        return result
    }

    private func describe(_ image: CGImage) -> String {
        return "\(image.width)x\(image.height) bpc \(image.bitsPerComponent) bpp \(image.bitsPerPixel) \(image.colorSpace?.name.map { $0 as String } ?? "-")"
    }

    private func isGray(_ image: CGImage) -> Bool {
        return image.colorSpace?.model == .monochrome
    }

    private static let font = UIFont.systemFont(ofSize: 17.0)
    private static let text = "Hello, this is a chat message line that wraps onto a second line"

    private func attributed(_ color: UIColor, _ string: String = ASGraphicsRasterizationTests.text, extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: ASGraphicsRasterizationTests.font, .foregroundColor: color]
        for (key, value) in extra {
            attributes[key] = value
        }
        return NSAttributedString(string: string, attributes: attributes)
    }

    private struct Case {
        let name: String
        let string: NSAttributedString
        let expectGray: Bool
    }

    private var cases: [Case] {
        let mixed = NSMutableAttributedString(attributedString: self.attributed(UIColor.black))
        mixed.addAttribute(.foregroundColor, value: UIColor(rgb: 0x007aff), range: NSRange(location: 7, length: 4))
        return [
            Case(name: "black", string: self.attributed(UIColor.black), expectGray: true),
            Case(name: "white", string: self.attributed(UIColor.white), expectGray: true),
            Case(name: "rgb black", string: self.attributed(UIColor(rgb: 0x000000)), expectGray: false),
            Case(name: "rgb gray", string: self.attributed(UIColor(rgb: 0x808080)), expectGray: false),
            Case(name: "half alpha black", string: self.attributed(UIColor(white: 0.0, alpha: 0.5)), expectGray: true),
            Case(name: "secondary gray", string: self.attributed(UIColor(rgb: 0x8e8e93)), expectGray: false),
            Case(name: "blue", string: self.attributed(UIColor(rgb: 0x007aff)), expectGray: false),
            Case(name: "black with link", string: mixed, expectGray: false),
            Case(name: "emoji", string: self.attributed(UIColor.black, "Hello 😀 world 🎉 and more text"), expectGray: false),
            Case(name: "strikethrough", string: self.attributed(UIColor.black, extra: [.strikethroughStyle: NSUnderlineStyle.single.rawValue]), expectGray: true),
            Case(name: "rtl", string: self.attributed(UIColor.black, "שלום עולם, זו שורה של טקסט"), expectGray: true),
        ]
    }

    // MARK: - Formats and pixels

    func testTextNodePixelsMatchAutomaticRenderer() {
        print("[ASRaster] displayGamut P3: \(UIScreen.main.traitCollection.displayGamut == .P3), scale \(self.scale)")
        for testCase in self.cases {
            let node = self.makeTextNode(testCase.string)
            guard let reference = self.automaticRendererImage(for: node) else {
                XCTFail("no reference for \(testCase.name)")
                continue
            }
            node.displayImmediately()
            guard let image = self.cgImage(node.layer.contents) else {
                XCTFail("no contents for \(testCase.name)")
                continue
            }
            print("[ASRaster] \(testCase.name): automatic \(self.describe(reference)) | node \(self.describe(image))")
            XCTAssertEqual(image.width, reference.width, testCase.name)
            XCTAssertEqual(image.height, reference.height, testCase.name)
            let difference = self.maxChannelDifference(reference, image)
            let standardDifference = self.automaticRendererImage(for: node, standardRange: true).map { self.maxChannelDifference($0, image) } ?? -1
            print("[ASRaster] \(testCase.name): max channel difference \(difference), to a standard-range render \(standardDifference)")
            XCTAssertLessThanOrEqual(difference, 2, testCase.name)
        }
    }

    /// A fractional node size gets the same pixel size as the renderer gave it.
    func testFractionalBoundsKeepRendererPixelSize() {
        for size in [CGSize(width: 100.5, height: 20.33), CGSize(width: 77.34, height: 18.67), CGSize(width: 0.4, height: 0.4)] {
            let node = self.makeTextNode(self.attributed(UIColor.black, "Hi"))
            node.frame = CGRect(origin: CGPoint(), size: size)
            guard let reference = self.automaticRendererImage(for: node) else {
                XCTFail("no reference")
                continue
            }
            node.displayImmediately()
            guard let image = self.cgImage(node.layer.contents) else {
                XCTFail("no contents for \(size)")
                continue
            }
            print("[ASRaster] fractional \(size): automatic \(self.describe(reference)) | node \(self.describe(image))")
            XCTAssertEqual(image.width, reference.width)
            XCTAssertEqual(image.height, reference.height)
            XCTAssertLessThanOrEqual(self.maxChannelDifference(reference, image), 2)
        }
    }

    /// Monochrome text must not double its memory: it stays an 8-bit gray + alpha bitmap, as the
    /// `.automatic` renderer made it.
    func testMonochromeTextStaysGray() {
        for testCase in self.cases {
            let node = self.makeTextNode(testCase.string)
            node.displayImmediately()
            guard let image = self.cgImage(node.layer.contents) else {
                XCTFail("no contents for \(testCase.name)")
                continue
            }
            if testCase.expectGray {
                XCTAssertTrue(self.isGray(image), "\(testCase.name): \(self.describe(image))")
                XCTAssertEqual(image.bitsPerPixel, 16, testCase.name)
            } else {
                XCTAssertFalse(self.isGray(image), "\(testCase.name): \(self.describe(image))")
            }
        }
    }

    /// Text drawn with a shadow or stroke, or over a background, is never treated as gray by mistake.
    func testShadowAndStrokeAreNotGray() {
        let shadowed = self.makeTextNode(self.attributed(UIColor.black)) { node in
            node.textShadowColor = UIColor(rgb: 0xff0000)
        }
        shadowed.displayImmediately()
        let stroked = self.makeTextNode(self.attributed(UIColor.black)) { node in
            node.textStroke = (UIColor(rgb: 0x00ff00), 1.0)
        }
        stroked.displayImmediately()
        for (name, node) in [("shadow", shadowed), ("stroke", stroked)] {
            guard let image = self.cgImage(node.layer.contents), let automatic = self.automaticRendererImage(for: node), let standard = self.automaticRendererImage(for: node, standardRange: true) else {
                XCTFail("no contents")
                continue
            }
            print("[ASRaster] \(name): automatic \(self.describe(automatic)) | node \(self.describe(image)); difference to automatic \(self.maxChannelDifference(automatic, image)), to standard \(self.maxChannelDifference(standard, image))")
            XCTAssertFalse(self.isGray(image), "\(name): \(self.describe(image))")
            // The coloured shadow or stroke keeps its colour.
            XCTAssertLessThanOrEqual(self.maxChannelDifference(standard, image), 2, name)
        }
    }

    /// The renderer path with a colour: 8 bits per channel, never a wide or float format.
    func testColoredDrawingUsesStandardRange() {
        let node = ColoredDrawingNode()
        node.frame = CGRect(x: 0.0, y: 0.0, width: 260.0, height: 40.0)
        node.displaysAsynchronously = false
        _ = node.layer
        node.setNeedsDisplayAtScale(self.scale)
        node.displayImmediately()
        guard let cgImage = self.cgImage(node.layer.contents) else {
            XCTFail("no image")
            return
        }
        print("[ASRaster] colored node: \(self.describe(cgImage))")
        XCTAssertEqual(cgImage.bitsPerComponent, 8)
        XCTAssertEqual(cgImage.bitsPerPixel, 32)
        XCTAssertEqual(cgImage.colorSpace?.name, CGColorSpace.sRGB)
    }

    // MARK: - Benchmarks (printed, not asserted)

    private func bestMicroseconds(_ iterations: Int, _ f: () -> Void) -> (best: Double, average: Double) {
        for _ in 0 ..< 20 {
            autoreleasepool { f() }
        }
        var best = Double.greatestFiniteMagnitude
        let start = CACurrentMediaTime()
        for _ in 0 ..< iterations {
            let t = CACurrentMediaTime()
            autoreleasepool { f() }
            best = min(best, CACurrentMediaTime() - t)
        }
        return (best * 1e6, (CACurrentMediaTime() - start) / Double(iterations) * 1e6)
    }

    func testBenchmarkTextNodeDisplay() {
        for (name, string) in [("black", self.attributed(UIColor.black)), ("blue", self.attributed(UIColor(rgb: 0x007aff)))] {
            let node = self.makeTextNode(string)
            let automatic = self.bestMicroseconds(300) {
                _ = self.automaticRendererImage(for: node)
            }
            let display = self.bestMicroseconds(300) {
                node.displayImmediately()
            }
            print(String(format: "[ASRaster] bench %@ text %.0fx%.0f: automatic renderer best %.1f us avg %.1f us | node display best %.1f us avg %.1f us", name, node.bounds.width, node.bounds.height, automatic.best, automatic.average, display.best, display.average))
        }
    }

    func testBenchmarkColoredNodeDisplay() {
        let node = ColoredDrawingNode()
        node.frame = CGRect(x: 0.0, y: 0.0, width: 260.0, height: 40.0)
        node.displaysAsynchronously = false
        _ = node.layer
        node.setNeedsDisplayAtScale(self.scale)
        let display = self.bestMicroseconds(300) {
            node.displayImmediately()
        }
        print(String(format: "[ASRaster] bench colored node display 260x40: best %.1f us avg %.1f us", display.best, display.average))
    }

    func testBenchmarkActiveProcessorCount() {
        let iterations = 100000
        var sum = 0
        let start = CACurrentMediaTime()
        for _ in 0 ..< iterations {
            sum &+= ProcessInfo.processInfo.activeProcessorCount
        }
        let elapsed = CACurrentMediaTime() - start
        print(String(format: "[ASRaster] activeProcessorCount %.3f us per call (sum %d)", elapsed / Double(iterations) * 1e6, sum))
    }
}

/// A node that draws blue text and a filled circle, like the typing indicator and spinners.
private final class ColoredDrawingNode: ASDisplayNode {
    private static let text = NSAttributedString(string: "Hello, this is a chat message line", attributes: [.font: UIFont.systemFont(ofSize: 17.0), .foregroundColor: UIColor(rgb: 0x007aff)])

    override init() {
        super.init()
        self.isOpaque = false
    }

    override class func draw(_ bounds: CGRect, withParameters parameters: Any?, isCancelled: () -> Bool, isRasterizing: Bool) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        context.setFillColor(UIColor(rgb: 0x34c759).cgColor)
        context.fillEllipse(in: CGRect(x: 220.0, y: 8.0, width: 24.0, height: 24.0))
        ColoredDrawingNode.text.draw(at: CGPoint(x: 4.0, y: 10.0))
    }
}
