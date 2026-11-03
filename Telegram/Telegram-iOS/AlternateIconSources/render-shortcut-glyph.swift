// Draws the Comet from the app icon as monochrome template glyphs (iOS tints them; only alpha matters):
// - Icons.xcassets/Shortcuts/AppIcon.imageset/comet_24.pdf: the Home Screen quick-action glyph, 24 pt;
// - TelegramUI Images.xcassets/Call/NanogramCallKitLogo.imageset: the CallKit logo (lock-screen call,
//   Phone > Recents), 40 pt template PNGs at @2x and @3x;
// - TelegramUI Images.xcassets/Call/NanogramCallTitleLogo.imageset/comet_15.pdf: next to the call status, 15 pt.
// Re-run (all, or only the named ones: shortcut, callkit, calltitle):
//   swift Telegram/Telegram-iOS/AlternateIconSources/render-shortcut-glyph.swift [names...]
import CoreGraphics
import Foundation
import ImageIO

/// Unwraps a value the script cannot continue without, or stops with a message.
func required<T>(_ value: T?, _ what: String) -> T {
    guard let value else {
        fatalError("could not create \(what)")
    }
    return value
}

let space = required(CGColorSpace(name: CGColorSpace.sRGB), "sRGB colour space")

/// Draws the comet into a `side` x `side` box with y up, fitted into `side - 2 * margin`, centred.
func drawComet(_ context: CGContext, side: CGFloat, margin: CGFloat) {
    // Icon coordinates (1024 units, y down): the comet spans x 176...809, y 215...848 (633 square).
    let scale: CGFloat = (side - 2.0 * margin) / 633.0
    context.saveGState()
    context.translateBy(x: margin - 176.0 * scale, y: side - (margin - 215.0 * scale))
    context.scaleBy(x: scale, y: -scale)
    // Tail: opaque at the head, fading out at the tip.
    context.saveGState()
    context.move(to: CGPoint(x: 752, y: 550))
    context.addLine(to: CGPoint(x: 176, y: 848))
    context.addLine(to: CGPoint(x: 474, y: 272))
    context.closePath()
    context.clip()
    let opaque = required(CGColor(colorSpace: space, components: [0, 0, 0, 1]), "colour")
    let faint = required(CGColor(colorSpace: space, components: [0, 0, 0, 0.15]), "colour")
    let tail = required(CGGradient(colorsSpace: space, colors: [opaque, faint] as CFArray, locations: [0, 1]), "gradient")
    context.drawLinearGradient(tail, start: CGPoint(x: 613, y: 411), end: CGPoint(x: 176, y: 848), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    // Head.
    context.setFillColor(opaque)
    context.fillEllipse(in: CGRect(x: 613 - 196, y: 411 - 196, width: 392, height: 392))
    context.restoreGState()
}

func writePDF(_ url: URL, side: CGFloat, margin: CGFloat) {
    var box = CGRect(x: 0, y: 0, width: side, height: side)
    let pdf = required(CGContext(url as CFURL, mediaBox: &box, nil), "PDF context")
    pdf.beginPDFPage(nil)
    drawComet(pdf, side: side, margin: margin)
    pdf.endPDFPage()
    pdf.closePDF()
    print(url.path)
}

func writePNG(_ url: URL, points: CGFloat, margin: CGFloat, scale: CGFloat) {
    let pixels = Int(points * scale)
    let bitmap = required(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "bitmap")
    bitmap.scaleBy(x: scale, y: scale)
    drawComet(bitmap, side: points, margin: margin)
    let image = required(bitmap.makeImage(), "image")
    let destination = required(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil), "PNG destination")
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(url.path)")
    }
    print(url.path)
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repository = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let callAssets = repository.appendingPathComponent("submodules/TelegramUI/Images.xcassets/Call")
let requested = Set(CommandLine.arguments.dropFirst())

func wanted(_ name: String) -> Bool {
    return requested.isEmpty || requested.contains(name)
}

if wanted("shortcut") {
    writePDF(here.deletingLastPathComponent().appendingPathComponent("Icons.xcassets/Shortcuts/AppIcon.imageset/comet_24.pdf"), side: 24.0, margin: 1.0)
}
if wanted("callkit") {
    // CallKit takes a 40 pt square template image (CXProviderConfiguration.iconTemplateImageData).
    let directory = callAssets.appendingPathComponent("NanogramCallKitLogo.imageset")
    for scale in [2.0, 3.0] as [CGFloat] {
        writePNG(directory.appendingPathComponent("NanogramCallKitLogo@\(Int(scale))x.png"), points: 40.0, margin: 2.0, scale: scale)
    }
}
if wanted("calltitle") {
    writePDF(callAssets.appendingPathComponent("NanogramCallTitleLogo.imageset/comet_15.pdf"), side: 15.0, margin: 0.0)
}
