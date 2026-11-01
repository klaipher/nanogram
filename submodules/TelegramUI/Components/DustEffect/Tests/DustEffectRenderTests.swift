import Foundation
import CoreGraphics
import Metal
import MetalKit
import XCTest

// Renders the effect offscreen the way DustEffectLayer does, with the shaders compiled from the module's sources.
final class DustEffectRenderTests: XCTestCase {
    private struct Context {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let computePipelines: DustEffectComputePipelines
        let renderPipeline: MTLRenderPipelineState
    }

    private func metalSourcePaths() throws -> [String] {
        guard let value = ProcessInfo.processInfo.environment["DUST_EFFECT_METAL_SOURCES"] else {
            throw XCTSkip("DUST_EFFECT_METAL_SOURCES is not set")
        }
        let environment = ProcessInfo.processInfo.environment
        var bases = [FileManager.default.currentDirectoryPath]
        if let sourceDirectory = environment["TEST_SRCDIR"] {
            bases.append(sourceDirectory + "/" + (environment["TEST_WORKSPACE"] ?? "_main"))
            bases.append(sourceDirectory + "/_main")
        }
        return try value.split(separator: " ").map { relativePath in
            for base in bases {
                let path = base + "/" + relativePath
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
            throw XCTSkip("Shader source not found: \(relativePath)")
        }
    }

    // The sources as one translation unit: the runtime compiler resolves no includes.
    private func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let paths = try self.metalSourcePaths()
        var header = ""
        var body = ""
        for path in paths {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            if path.hasSuffix("loki_header.metal") {
                header = text
            } else {
                body += text.components(separatedBy: "\n").filter { !$0.hasPrefix("#include \"") }.joined(separator: "\n") + "\n"
            }
        }
        XCTAssertFalse(header.isEmpty)
        // Loki's address-space-qualified methods are rejected by Metal 3; the app's build compiles at an older version.
        let options = MTLCompileOptions()
        options.languageVersion = .version2_4
        return try device.makeLibrary(source: header + "\n" + body, options: options)
    }

    private func makeContext() throws -> Context {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        let library = try self.makeLibrary(device: device)
        let computePipelines = try XCTUnwrap(DustEffectComputePipelines(library: library, makePipelineState: { try? device.makeComputePipelineState(function: $0) }))
        let descriptor = try XCTUnwrap(DustEffectRenderPipeline.descriptor(library: library))
        let renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        return Context(device: device, queue: queue, computePipelines: computePipelines, renderPipeline: renderPipeline)
    }

    // An opaque bubble with lines of "text" and transparent corners, in premultiplied BGRA.
    private func makeBubbleImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1.0))
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: 40, cornerHeight: 40, transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 0.8, alpha: 1.0))
        var y = 30
        while y < height - 40 {
            context.fill(CGRect(x: 30, y: y, width: width - 90, height: 14))
            y += 45
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeTarget(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func readPixels(_ texture: MTLTexture) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                texture.getBytes(baseAddress, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
        }
        return pixels
    }

    // One frame: the layer's update (compute, then render into a cleared target).
    private func renderFrame(context: Context, simulation: DustEffectSimulation, containerSize: CGSize, target: MTLTexture, scale: Float) throws {
        simulation.prepare(device: context.device, containerSize: containerSize)
        let commandBuffer = try XCTUnwrap(context.queue.makeCommandBuffer())
        let computeEncoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        simulation.encodeCompute(encoder: computeEncoder, pipelines: context.computePipelines, containerSize: containerSize)
        computeEncoder.endEncoding()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        pass.colorAttachments[0].storeAction = .store
        let renderEncoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        renderEncoder.setRenderPipelineState(context.renderPipeline)
        simulation.encodeRender(encoder: renderEncoder, effectiveRect: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0), containerSize: containerSize, pixelsPerPoint: scale)
        renderEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
    }

    private let containerSize = CGSize(width: 240.0, height: 400.0)
    private let itemFrame = CGRect(x: 40.0, y: 280.0, width: 160.0, height: 48.0)

    private func makeSimulation(context: Context, scale: Int) throws -> (DustEffectSimulation, CGImage) {
        let image = try self.makeBubbleImage(width: Int(self.itemFrame.width) * scale, height: Int(self.itemFrame.height) * scale)
        let texture = try MTKTextureLoader(device: context.device).newTexture(cgImage: image, options: [.SRGB: false as NSNumber])
        let simulation = DustEffectSimulation(randomGenerator: DustEffectRandomNumberGenerator(seed: 42))
        simulation.addItem(frame: self.itemFrame, texture: texture, quality: .full)
        return (simulation, image)
    }

    // Before any time passes every grain is its own square of the message, so the frame is the snapshot.
    func testFirstFrameIsTheSnapshot() throws {
        let context = try self.makeContext()
        for scale in [2, 3] {
            let (simulation, image) = try self.makeSimulation(context: context, scale: scale)
            let target = try self.makeTarget(device: context.device, width: Int(self.containerSize.width) * scale, height: Int(self.containerSize.height) * scale)
            try self.renderFrame(context: context, simulation: simulation, containerSize: self.containerSize, target: target, scale: Float(scale))
            let pixels = self.readPixels(target)

            let imageData = try XCTUnwrap(image.dataProvider?.data as Data?)
            let imageBytesPerRow = image.bytesPerRow
            var maxDifference = 0
            var outsideCount = 0
            let originX = Int(self.itemFrame.minX) * scale
            let originY = Int(self.itemFrame.minY) * scale
            for y in 0 ..< target.height {
                for x in 0 ..< target.width {
                    let offset = (y * target.width + x) * 4
                    let insideX = x - originX
                    let insideY = y - originY
                    if insideX >= 0 && insideX < image.width && insideY >= 0 && insideY < image.height {
                        let imageOffset = insideY * imageBytesPerRow + insideX * 4
                        for channel in 0 ..< 4 {
                            maxDifference = max(maxDifference, abs(Int(pixels[offset + channel]) - Int(imageData[imageOffset + channel])))
                        }
                    } else if pixels[offset + 3] != 0 {
                        outsideCount += 1
                    }
                }
            }
            XCTAssertLessThanOrEqual(maxDifference, 1, "scale \(scale)")
            XCTAssertEqual(outsideCount, 0, "scale \(scale)")
        }
    }

    // The effect ends as soon as nothing is left to see: the frame drawn before the item is removed is empty, and
    // that is about 2.9 s in, not the 4 s it used to take.
    func testEffectEndsWhenTheLastGrainIsGone() throws {
        let context = try self.makeContext()
        let scale = 3
        let (simulation, _) = try self.makeSimulation(context: context, scale: scale)
        let target = try self.makeTarget(device: context.device, width: Int(self.containerSize.width) * scale, height: Int(self.containerSize.height) * scale)

        let deltaTime = 1.0 / 120.0
        var time = 0.0
        var visibleAtTime: [Double: Int] = [:]
        var lastFrameVisiblePixels = -1
        var endTime: Double?
        try self.renderFrame(context: context, simulation: simulation, containerSize: self.containerSize, target: target, scale: Float(scale))
        for _ in 0 ..< 1000 {
            time += deltaTime
            if simulation.advance(deltaTime: deltaTime, durationFactor: 1.0, containerHeight: Float(self.containerSize.height)) {
                endTime = time
                break
            }
            try self.renderFrame(context: context, simulation: simulation, containerSize: self.containerSize, target: target, scale: Float(scale))
            let isLastFrame = simulation.items.allSatisfy { $0.progress.isFinished }
            let sampleTimes: [Double] = [0.5, 1.5, 2.5]
            if isLastFrame || sampleTimes.contains(where: { abs($0 - time) < deltaTime * 0.5 }) {
                let pixels = self.readPixels(target)
                var visiblePixels = 0
                for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] != 0 {
                    visiblePixels += 1
                }
                if isLastFrame {
                    lastFrameVisiblePixels = visiblePixels
                } else {
                    visibleAtTime[(time * 10.0).rounded() / 10.0] = visiblePixels
                }
            }
        }
        let end = try XCTUnwrap(endTime)
        XCTAssertEqual(lastFrameVisiblePixels, 0)
        XCTAssertGreaterThan(end, 2.6)
        XCTAssertLessThan(end, 3.0)
        XCTAssertGreaterThan(visibleAtTime[0.5] ?? 0, 0)
        XCTAssertGreaterThan(visibleAtTime[1.5] ?? 0, 0)
        print("DustEffectRenderTests: ended at \(end) s; visible pixels at 0.5/1.5/2.5 s: \(visibleAtTime[0.5] ?? -1)/\(visibleAtTime[1.5] ?? -1)/\(visibleAtTime[2.5] ?? -1)")
    }
}
