import Foundation
import CoreGraphics
import Metal

// The effect's GPU work: particle state, the fluid, and the commands that update and draw them. Free of UIKit and
// MetalEngine so the host tests can render it offscreen; DustEffectLayer drives it from the display link.

final class DustEffectComputePipelines {
    let initializeParticle: MTLComputePipelineState
    let updateParticle: MTLComputePipelineState
    let fluid: DustFluidSimulation.Pipelines

    init?(library: MTLLibrary, makePipelineState: (MTLFunction) -> MTLComputePipelineState?) {
        guard let initializeFunction = library.makeFunction(name: "dustEffectInitializeParticle"), let initializeParticle = makePipelineState(initializeFunction) else {
            return nil
        }
        guard let updateFunction = library.makeFunction(name: "dustEffectUpdateParticle"), let updateParticle = makePipelineState(updateFunction) else {
            return nil
        }
        guard let fluid = DustFluidSimulation.Pipelines(library: library, makePipelineState: makePipelineState) else {
            return nil
        }
        self.initializeParticle = initializeParticle
        self.updateParticle = updateParticle
        self.fluid = fluid
    }
}

enum DustEffectRenderPipeline {
    static func descriptor(library: MTLLibrary) -> MTLRenderPipelineDescriptor? {
        guard let vertexFunction = library.makeFunction(name: "dustEffectVertex"), let fragmentFunction = library.makeFunction(name: "dustEffectFragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        return descriptor
    }
}

// The system generator, or a seeded one so tests can repeat a run exactly.
struct DustEffectRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64?

    init(seed: UInt64? = nil) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        guard var state = self.state else {
            var system = SystemRandomNumberGenerator()
            return system.next()
        }
        // SplitMix64.
        state = state &+ 0x9e3779b97f4a7c15
        self.state = state
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

final class DustEffectSimulation {
    final class Item {
        // In the container, origin at the top left.
        let frame: CGRect
        let texture: MTLTexture
        let columns: Int
        let rows: Int

        var phase: Float = 0.0
        // Animation seconds since the item was added.
        var duration: Double = 0.0
        var progress = DustEffectItemProgress()
        var particleBufferIsInitialized: Bool = false
        var particleBuffer: MTLBuffer?

        var particleCount: Int {
            return self.columns * self.rows
        }

        init(frame: CGRect, texture: MTLTexture, columns: Int, rows: Int) {
            self.frame = frame
            self.texture = texture
            self.columns = columns
            self.rows = rows
        }
    }

    // Matches ParticleFluidParams in DustEffectShaders.metal.
    private struct ParticleFluidParams {
        var itemOrigin: SIMD2<Float>
        var itemSize: SIMD2<Float>
        var cellSize: Float
        var isEnabled: Float
    }

    // Particle in DustEffectShaders.metal: offset, velocity, lifetime, age, displacement.
    static let particleStride = 4 * (2 + 2 + 1 + 1 + 2)

    private(set) var items: [Item] = []
    private(set) var fluid: DustFluidSimulation?
    private var isFluidEnabled: Bool = true
    private var pendingFluidSplats: [DustFluidSimulation.Splat] = []
    // Seconds of the frame not yet simulated on the GPU, before the slow-animations factor.
    private var pendingTimeStep: Double = 0.0
    private var pendingDurationFactor: Double = 1.0
    var randomGenerator: DustEffectRandomNumberGenerator

    var animationSpeed: Float = 1.0
    var animateDown: Bool = false

    init(randomGenerator: DustEffectRandomNumberGenerator = DustEffectRandomNumberGenerator()) {
        self.randomGenerator = randomGenerator
    }

    // The last update's time step, for lag logging.
    var lastTimeStep: Double {
        return self.pendingTimeStep
    }

    // Whether some item is still coming apart. Its grains move fast; afterwards they drift.
    var isSweeping: Bool {
        return self.items.contains(where: { $0.phase < DustEffectTiming.sweepDuration })
    }

    func addItem(frame: CGRect, texture: MTLTexture, quality: DustEffectQuality) {
        let grid = quality.particleGrid(itemSize: frame.size)
        if grid.columns == 0 || grid.rows == 0 {
            return
        }
        if self.items.isEmpty {
            self.isFluidEnabled = quality.isFluidEnabled
        }
        self.items.append(Item(frame: frame, texture: texture, columns: grid.columns, rows: grid.rows))
    }

    // Moves the animation on by `deltaTime` seconds; `durationFactor` is UIKit's slow-animations factor. Returns true
    // when this removed the last item.
    func advance(deltaTime: Double, durationFactor: Double, containerHeight: Float) -> Bool {
        self.pendingTimeStep = deltaTime
        self.pendingDurationFactor = durationFactor

        let verticalDirection: Float = self.animateDown ? -1.0 : 1.0

        var didRemoveItems = false
        for i in (0 ..< self.items.count).reversed() {
            let item = self.items[i]
            let previousPhase = item.phase
            item.phase += Float(deltaTime) * self.animationSpeed / Float(durationFactor)
            item.duration += deltaTime / durationFactor

            // Every grain has gone out: they all move at full speed from the end of the sweep. The time limit only
            // ends an item the GPU never got to simulate.
            if item.progress.isFinished || item.duration >= DustEffectTiming.maxDuration(animationSpeed: self.animationSpeed) {
                self.items.remove(at: i)
                didRemoveItems = true
            } else {
                let itemOrigin = SIMD2<Float>(Float(item.frame.minX), containerHeight - Float(item.frame.maxY))
                let itemSize = SIMD2<Float>(Float(item.frame.width), Float(item.frame.height))
                let splats = DustFluidSimulation.dissolveSplats(itemOrigin: itemOrigin, itemSize: itemSize, previousPhase: previousPhase, phase: item.phase, verticalDirection: verticalDirection, generator: &self.randomGenerator)
                self.pendingFluidSplats.append(contentsOf: splats)
            }
        }

        if didRemoveItems && self.items.isEmpty {
            self.fluid = nil
            self.pendingFluidSplats.removeAll()
            self.isFluidEnabled = true
            return true
        }
        return false
    }

    // Allocates what the next frame needs.
    func prepare(device: MTLDevice, containerSize: CGSize) {
        for item in self.items {
            if item.particleBuffer == nil && item.particleCount > 0 {
                // Written by dustEffectInitializeParticle and read only by the GPU.
                let buffer = device.makeBuffer(length: item.particleCount * DustEffectSimulation.particleStride, options: [.storageModePrivate])
                buffer?.label = "DustEffect.particles"
                item.particleBuffer = buffer
            }
        }

        let fluidSize = SIMD2<Float>(Float(containerSize.width), Float(containerSize.height))
        if self.isFluidEnabled && !self.items.isEmpty && self.fluid?.size != fluidSize {
            self.fluid = DustFluidSimulation(device: device, size: fluidSize)
        }
    }

    func encodeCompute(encoder computeEncoder: MTLComputeCommandEncoder, pipelines: DustEffectComputePipelines, containerSize: CGSize) {
        let lastTimeStep = self.pendingTimeStep
        let durationFactor = self.pendingDurationFactor
        self.pendingTimeStep = 0.0

        var verticalDirection: Float = self.animateDown ? -1.0 : 1.0

        let fluid = self.fluid
        if let fluid, lastTimeStep != 0.0 {
            var timeStep: Float = Float(lastTimeStep) / Float(durationFactor)
            timeStep *= 2.0
            fluid.encode(encoder: computeEncoder, pipelines: pipelines.fluid, timeStep: timeStep, splats: self.pendingFluidSplats)
            self.pendingFluidSplats.removeAll()
        }

        for item in self.items {
            guard let particleBuffer = item.particleBuffer else {
                continue
            }

            let itemFrame = item.frame
            var particleCount = SIMD2<UInt32>(UInt32(clamping: item.columns), UInt32(clamping: item.rows))

            let threadgroupSize = MTLSize(width: 32, height: 1, depth: 1)
            let threadgroupCount = MTLSize(width: (item.particleCount + threadgroupSize.width - 1) / threadgroupSize.width, height: 1, depth: 1)

            computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)

            if !item.particleBufferIsInitialized {
                item.particleBufferIsInitialized = true
                computeEncoder.setComputePipelineState(pipelines.initializeParticle)
                computeEncoder.setBytes(&verticalDirection, length: 4, index: 1)
                computeEncoder.setBytes(&particleCount, length: 4 * 2, index: 2)
                computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            }

            if lastTimeStep != 0.0 {
                computeEncoder.setComputePipelineState(pipelines.updateParticle)
                computeEncoder.setBytes(&particleCount, length: 4 * 2, index: 1)
                var phase = item.phase
                computeEncoder.setBytes(&phase, length: 4, index: 2)
                var timeStep: Float = Float(lastTimeStep) / Float(durationFactor)
                timeStep *= 2.0
                computeEncoder.setBytes(&timeStep, length: 4, index: 3)
                computeEncoder.setBytes(&verticalDirection, length: 4, index: 4)

                var fluidParams = ParticleFluidParams(
                    itemOrigin: SIMD2<Float>(Float(itemFrame.minX), Float(containerSize.height - itemFrame.maxY)),
                    itemSize: SIMD2<Float>(Float(itemFrame.width), Float(itemFrame.height)),
                    cellSize: fluid?.cellSize ?? 1.0,
                    isEnabled: fluid != nil ? 1.0 : 0.0
                )
                computeEncoder.setBytes(&fluidParams, length: MemoryLayout<ParticleFluidParams>.stride, index: 5)
                // Without a fluid the kernel does not read the texture, but one must still be bound.
                computeEncoder.setTexture(fluid?.streamFunctionTexture ?? item.texture, index: 0)
                computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)

                item.progress.didDispatchUpdate(phase: phase, simulationTimeStep: Double(timeStep))
            }
        }
    }

    // `effectiveRect` is where the layer's allocation sits in the render target, in normalized coordinates.
    func encodeRender(encoder: MTLRenderCommandEncoder, effectiveRect layerRect: CGRect, containerSize: CGSize, pixelsPerPoint: Float) {
        for item in self.items {
            guard let particleBuffer = item.particleBuffer else {
                continue
            }

            var itemFrame = item.frame
            itemFrame.origin.y = containerSize.height - itemFrame.maxY

            var effectiveRect = layerRect
            effectiveRect.origin.x += itemFrame.minX / containerSize.width * effectiveRect.width
            effectiveRect.origin.y += itemFrame.minY / containerSize.height * effectiveRect.height
            effectiveRect.size.width = itemFrame.width / containerSize.width * effectiveRect.width
            effectiveRect.size.height = itemFrame.height / containerSize.height * effectiveRect.height

            var rect = SIMD4<Float>(Float(effectiveRect.minX), Float(effectiveRect.minY), Float(effectiveRect.width), Float(effectiveRect.height))
            encoder.setVertexBytes(&rect, length: 4 * 4, index: 0)

            var size = SIMD2<Float>(Float(itemFrame.width), Float(itemFrame.height))
            encoder.setVertexBytes(&size, length: 4 * 2, index: 1)

            var particleResolution = SIMD2<UInt32>(UInt32(clamping: item.columns), UInt32(clamping: item.rows))
            encoder.setVertexBytes(&particleResolution, length: 4 * 2, index: 2)

            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 3)

            var onePixel: Float = 1.0 / max(1.0, pixelsPerPoint)
            encoder.setVertexBytes(&onePixel, length: 4, index: 4)

            encoder.setFragmentTexture(item.texture, index: 0)

            // One quad per grain, as a strip of two triangles.
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: item.particleCount)
        }
    }
}
