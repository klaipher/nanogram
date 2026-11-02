// Draws the Home Screen quick-action glyph (Icons.xcassets/Shortcuts/AppIcon.imageset/comet_24.pdf):
// the Comet from the app icon as a 24 pt template image (iOS tints it; only alpha matters). Re-run:
//   swift Telegram/Telegram-iOS/AlternateIconSources/render-shortcut-glyph.swift
import CoreGraphics
import Foundation

/// Unwraps a value the script cannot continue without, or stops with a message.
func required<T>(_ value: T?, _ what: String) -> T {
    guard let value else {
        fatalError("could not create \(what)")
    }
    return value
}


let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let url = here.deletingLastPathComponent().appendingPathComponent("Icons.xcassets/Shortcuts/AppIcon.imageset/comet_24.pdf")
var box = CGRect(x: 0, y: 0, width: 24, height: 24)
let pdf = required(CGContext(url as CFURL, mediaBox: &box, nil), "PDF context")
pdf.beginPDFPage(nil)
// Icon coordinates (1024 units, y down): the comet spans x 176...809, y 215...848. Fit it into 22 pt, centred.
let scale: CGFloat = 22.0 / 633.0
pdf.translateBy(x: 1.0 - 176.0 * scale, y: 24.0 - (1.0 - 215.0 * scale))
pdf.scaleBy(x: scale, y: -scale)
let space = required(CGColorSpace(name: CGColorSpace.sRGB), "sRGB colour space")
// Tail: opaque at the head, fading out at the tip.
pdf.saveGState()
pdf.move(to: CGPoint(x: 752, y: 550))
pdf.addLine(to: CGPoint(x: 176, y: 848))
pdf.addLine(to: CGPoint(x: 474, y: 272))
pdf.closePath()
pdf.clip()
let opaque = required(CGColor(colorSpace: space, components: [0, 0, 0, 1]), "colour")
let faint = required(CGColor(colorSpace: space, components: [0, 0, 0, 0.15]), "colour")
let tail = required(CGGradient(colorsSpace: space, colors: [opaque, faint] as CFArray, locations: [0, 1]), "gradient")
pdf.drawLinearGradient(tail, start: CGPoint(x: 613, y: 411), end: CGPoint(x: 176, y: 848), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
pdf.restoreGState()
// Head.
pdf.setFillColor(opaque)
pdf.fillEllipse(in: CGRect(x: 613 - 196, y: 411 - 196, width: 392, height: 392))
pdf.endPDFPage()
pdf.closePDF()
print(url.path)
