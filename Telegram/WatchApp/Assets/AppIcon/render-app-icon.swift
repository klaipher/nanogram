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
// icon.json fill: navy #111722.
ctx.setFillColor(color(0.06667, 0.09020, 0.13333, 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
// The comet's light blue, #508FFF.
let blue: (CGFloat, CGFloat, CGFloat) = (0.31373, 0.56078, 1.0)

// Tail.svg: triangle M752 550 L176 848 L474 272 Z, blue 0.95 -> 0 from (613,411) to (176,848).
ctx.saveGState()
ctx.move(to: CGPoint(x: 752, y: 550))
ctx.addLine(to: CGPoint(x: 176, y: 848))
ctx.addLine(to: CGPoint(x: 474, y: 272))
ctx.closePath()
ctx.clip()
guard let tail = CGGradient(colorsSpace: cs, colors: [color(blue.0, blue.1, blue.2, 0.95), color(blue.0, blue.1, blue.2, 0)] as CFArray, locations: [0, 1]) else {
    fatalError("could not create the tail gradient")
}
ctx.drawLinearGradient(tail, start: CGPoint(x: 613, y: 411), end: CGPoint(x: 176, y: 848), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// Head.svg: blue circle at (613, 411), r 196.
ctx.setFillColor(color(blue.0, blue.1, blue.2, 1))
ctx.fillEllipse(in: CGRect(x: 613 - 196, y: 411 - 196, width: 392, height: 392))

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
precondition(CGImageDestinationFinalize(dest))
