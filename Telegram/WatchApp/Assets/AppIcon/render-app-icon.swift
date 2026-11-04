// Renders Telegram/Telegram-iOS/AlternateIconSources/NanogramSphere.svg (the app icon, a full-bleed square) as the flat,
// opaque 1024x1024 PNG of the watch app's AppIcon set; watchOS applies its own circle mask. Re-run after the iOS icon changes:
//   swift Assets/AppIcon/render-app-icon.swift "tgwatch Watch App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
// QuickLook (WebKit) rasterises the SVG, the same way as AlternateIconSources/render.swift.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let svg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Telegram-iOS/AlternateIconSources/NanogramSphere.svg")
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("watch-icon-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
process.arguments = ["-t", "-s", String(size), "-o", temp.path, svg.path]
process.standardOutput = FileHandle.nullDevice
process.standardError = FileHandle.nullDevice
try process.run()
process.waitUntilExit()
let rendered = temp.appendingPathComponent(svg.lastPathComponent + ".png")
guard let source = CGImageSourceCreateWithURL(rendered as CFURL, nil), let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("QuickLook did not render \(svg.lastPathComponent)")
}

guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
      let white = CGColor(colorSpace: cs, components: [1, 1, 1, 1]) else {
    fatalError("could not create the bitmap context")
}
ctx.setFillColor(white)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.interpolationQuality = .high
ctx.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("could not create the PNG writer")
}
CGImageDestinationAddImage(dest, image, nil)
precondition(CGImageDestinationFinalize(dest))
