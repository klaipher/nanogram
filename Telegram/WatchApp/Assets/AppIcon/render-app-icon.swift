// Renders Telegram/Telegram-iOS/Nanogram.icon (fill + Head.svg + Tail.svg) as a flat,
// opaque 1024x1024 PNG for the watch app's AppIcon set. Re-run after the iOS icon changes:
//   swift Assets/AppIcon/render-app-icon.swift "tgwatch Watch App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// SVG coordinates: origin top-left, y down.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}
// icon.json fill: linear gradient from top-right to bottom-left.
let fill = CGGradient(colorsSpace: cs, colors: [color(0.0, 0.76078, 0.81961, 1), color(0.04314, 0.16471, 0.41961, 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(fill, start: CGPoint(x: 1024, y: 0), end: CGPoint(x: 0, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Tail.svg: triangle M752 550 L176 848 L474 272 Z, white 0.95 -> 0 from (613,411) to (176,848).
ctx.saveGState()
ctx.move(to: CGPoint(x: 752, y: 550))
ctx.addLine(to: CGPoint(x: 176, y: 848))
ctx.addLine(to: CGPoint(x: 474, y: 272))
ctx.closePath()
ctx.clip()
let tail = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.95), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(tail, start: CGPoint(x: 613, y: 411), end: CGPoint(x: 176, y: 848), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// Head.svg: white circle at (613, 411), r 196.
ctx.setFillColor(color(1, 1, 1, 1))
ctx.fillEllipse(in: CGRect(x: 613 - 196, y: 411 - 196, width: 392, height: 392))

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
precondition(CGImageDestinationFinalize(dest))
