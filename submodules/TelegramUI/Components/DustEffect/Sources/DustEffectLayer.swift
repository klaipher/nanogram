import Foundation
import UIKit
import Display
import MetalEngine
import MetalKit

#if DEBUG
import os
#endif

#if DEBUG
class Signposter {
    func emitEvent(_ string: StaticString) {
    }
}

@available(iOS 15.0, *)
final class SignposterImpl: Signposter {
    private let signposter = OSSignposter()
    private let signpostId: OSSignpostID
    
    override init() {
        self.signpostId = self.signposter.makeSignpostID()
    }
    
    override func emitEvent(_ string: StaticString) {
        self.signposter.emitEvent("Fetch complete.", id: self.signpostId)
    }
}

let signposter: Signposter = {
    if #available(iOS 15.0, *) {
        return SignposterImpl()
    } else {
        return Signposter()
    }
}()

#endif

public final class DustEffectLayer: MetalEngineSubjectLayer, MetalEngineSubject {
    public var internalData: MetalEngineSubjectInternalData?
    
    private final class RenderState: RenderToLayerState {
        let pipelineState: MTLRenderPipelineState
        
        init?(device: MTLDevice) {
            guard let pipelineState = DustEffectPipelines.shared.render(device: device) else {
                return nil
            }
            self.pipelineState = pipelineState
        }
    }
    
    final class DustComputeState: ComputeState {
        let pipelines: DustEffectComputePipelines
        
        required init?(device: MTLDevice) {
            guard let pipelines = DustEffectPipelines.shared.compute(device: device) else {
                return nil
            }
            self.pipelines = pipelines
        }
    }
    
    // One loader for every item: making one per snapshot showed in profiles.
    private static let textureLoader = MTKTextureLoader(device: MetalEngine.shared.device)
    
    private var updateLink: SharedDisplayLinkDriver.Link?
    private var updateLinkIsHighFrameRate: Bool = false
    private var previousTargetTimestamp: Double?
    private let simulation = DustEffectSimulation()
    private var quality: DustEffectQuality = .full
    
    public var animationSpeed: Float = 1.0 {
        didSet {
            self.simulation.animationSpeed = self.animationSpeed
        }
    }
    public var playsBackwards: Bool = false
    public var animateDown: Bool = false {
        didSet {
            self.simulation.animateDown = self.animateDown
        }
    }
    
    public var becameEmpty: (() -> Void)?
    
    override public init() {
        super.init()
        
        self.isOpaque = false
        self.backgroundColor = nil
        
        self.didEnterHierarchy = { [weak self] in
            guard let self else {
                return
            }
            self.updateNeedsAnimation()
        }
        self.didExitHierarchy = { [weak self] in
            guard let self else {
                return
            }
            self.updateNeedsAnimation()
        }
    }
    
    override public init(layer: Any) {
        super.init(layer: layer)
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func updateItems(deltaTime: Double) {
        // Steps by the frames' target times, which is when they are shown.
        let targetTimestamp = SharedDisplayLinkDriver.shared.lastTargetTimestamp
        let deltaTimeValue = DustEffectTiming.frameDeltaTime(targetTimestamp: targetTimestamp, previousTargetTimestamp: self.previousTargetTimestamp, frameDuration: deltaTime)
        self.previousTargetTimestamp = targetTimestamp
        
        let becameEmpty = self.simulation.advance(deltaTime: deltaTimeValue, durationFactor: UIView.animationDurationFactor(), containerHeight: Float(self.bounds.height))
        self.updateNeedsAnimation()
        
        if becameEmpty {
            self.becameEmpty?()
        }
    }
    
    private func updateNeedsAnimation() {
        if !self.simulation.items.isEmpty && self.isInHierarchy {
            // 120 Hz while a message comes apart, 60 Hz for the slow drift after it.
            let isHighFrameRate = self.quality.usesHighFrameRateDuringSweep && self.simulation.isSweeping
            if self.updateLink != nil && self.updateLinkIsHighFrameRate != isHighFrameRate {
                self.updateLink = nil
            }
            if self.updateLink == nil {
                self.updateLinkIsHighFrameRate = isHighFrameRate
                self.updateLink = SharedDisplayLinkDriver.shared.add(framesPerSecond: isHighFrameRate ? .max : .fps(60), { [weak self] deltaTime in
                    guard let self else {
                        return
                    }
                    self.updateItems(deltaTime: Double(deltaTime))
                    self.setNeedsUpdate()
                })
            }
        } else {
            if self.updateLink != nil {
                self.updateLink = nil
            }
            self.previousTargetTimestamp = nil
        }
    }
    
    public func addItem(frame: CGRect, image: UIImage) {
        guard let cgImage = image.cgImage, let texture = try? DustEffectLayer.textureLoader.newTexture(cgImage: cgImage, options: [.SRGB: false as NSNumber]) else {
            return
        }
        if self.simulation.items.isEmpty {
            self.quality = DustEffectQuality.current()
        }
        self.simulation.addItem(frame: frame, texture: texture, quality: self.quality)
        self.updateNeedsAnimation()
        self.setNeedsUpdate()
    }
    
    public func update(context: MetalEngineSubjectContext) {
        if self.bounds.isEmpty {
            return
        }
        
        let containerSize = self.bounds.size
        let simulation = self.simulation
        simulation.prepare(device: MetalEngine.shared.device, containerSize: containerSize)
        
        #if DEBUG
        let lastTimeStep = simulation.lastTimeStep
        if lastTimeStep * 1000.0 >= 20.0 {
            print("Animation Lag: \(lastTimeStep * 1000.0) ms")
            signposter.emitEvent("AnimationLag")
        }
        #endif
        
        let _ = context.compute(state: DustComputeState.self, commands: { commandBuffer, state in
            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                return
            }
            simulation.encodeCompute(encoder: computeEncoder, pipelines: state.pipelines, containerSize: containerSize)
            computeEncoder.endEncoding()
        })
        
        // At the screen's own scale: a grain dwindles to one of its pixels.
        let scale = max(1.0, UIScreenScale)
        let renderSize = RenderSize(width: DustEffectLayer.pixelCount(containerSize.width * scale), height: DustEffectLayer.pixelCount(containerSize.height * scale))
        context.renderToLayer(spec: RenderLayerSpec(size: renderSize), state: RenderState.self, layer: self, commands: { encoder, placement in
            simulation.encodeRender(encoder: encoder, effectiveRect: placement.effectiveRect, containerSize: containerSize, pixelsPerPoint: Float(scale))
        })
    }
    
    private static func pixelCount(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0.0 else {
            return 0
        }
        return Int(min(value, 16384.0))
    }
}
