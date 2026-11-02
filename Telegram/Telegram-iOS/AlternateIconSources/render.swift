// Renders every <Name>.svg in this folder into ../<Name>.alticon/ as the opaque PNGs iOS needs for an
// alternate app icon (iPhone @2x/@3x, iPad, iPad @2x, iPad Pro). Re-run after changing a source:
//   swift Telegram/Telegram-iOS/AlternateIconSources/render.swift
// The SVGs are full-bleed squares (iOS applies the rounded mask). QuickLook (WebKit) rasterises them, so
// gradients, opacity and blur render as in a browser; each size is then drawn onto an opaque sRGB canvas.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Unwraps a value the script cannot continue without, or stops with a message.
func required<T>(_ value: T?, _ what: String) -> T {
    guard let value else {
        fatalError("could not create \(what)")
    }
    return value
}

/// Runs a throwing step the script cannot continue without, or stops with its error.
func attempt<T>(_ what: String, _ body: () throws -> T) -> T {
    do {
        return try body()
    } catch {
        fatalError("\(what) failed: \(error)")
    }
}

let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let outputRoot = sourceDir.deletingLastPathComponent()
let sizes: [(suffix: String, pixels: Int)] = [
    ("@2x", 120), ("@3x", 180), ("Ipad", 76), ("Ipad@2x", 152), ("LargeIpad@2x", 167),
]

func rasterize(_ svg: URL, into dir: URL) -> CGImage {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
    process.arguments = ["-t", "-s", "1024", "-o", dir.path, svg.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    attempt("qlmanage") { try process.run() }
    process.waitUntilExit()
    let png = dir.appendingPathComponent(svg.lastPathComponent + ".png")
    guard let source = CGImageSourceCreateWithURL(png as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("QuickLook did not render \(svg.lastPathComponent)")
    }
    return image
}

func writeOpaque(_ image: CGImage, pixels: Int, to url: URL) {
    let space = required(CGColorSpace(name: CGColorSpace.sRGB), "sRGB colour space")
    let context = required(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), "bitmap context")
    context.setFillColor(required(CGColor(colorSpace: space, components: [1, 1, 1, 1]), "white"))
    context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let destination = required(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil), "PNG writer")
    CGImageDestinationAddImage(destination, required(context.makeImage(), "image"), nil)
    precondition(CGImageDestinationFinalize(destination), "could not write \(url.path)")
}

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("alticons-\(UUID().uuidString)")
attempt("temp folder") { try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true) }
defer { try? FileManager.default.removeItem(at: temp) }

let svgs = attempt("listing sources") { try FileManager.default.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) }
    .filter { $0.pathExtension == "svg" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
for svg in svgs {
    let name = svg.deletingPathExtension().lastPathComponent
    let image = rasterize(svg, into: temp)
    let folder = outputRoot.appendingPathComponent("\(name).alticon")
    attempt("icon folder") { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    for size in sizes {
        writeOpaque(image, pixels: size.pixels, to: folder.appendingPathComponent("\(name)\(size.suffix).png"))
    }
    print("\(name): \(sizes.count) PNGs")
}
