import Foundation
import Metal
import MetalEngine

private final class BundleMarker: NSObject {
}

private let metalLibraryLock = NSLock()
private var metalLibraryValue: (device: MTLDevice, library: MTLLibrary)?

// The module's shaders, compiled at build time into DustEffectMetalSourcesBundle's default.metallib. Safe to call
// from any thread.
func metalLibrary(device: MTLDevice) -> MTLLibrary? {
    metalLibraryLock.lock()
    defer {
        metalLibraryLock.unlock()
    }
    if let metalLibraryValue, metalLibraryValue.device === device {
        return metalLibraryValue.library
    }
    let mainBundle = Bundle(for: BundleMarker.self)
    guard let path = mainBundle.path(forResource: "DustEffectMetalSourcesBundle", ofType: "bundle"), let bundle = Bundle(path: path) else {
        return nil
    }
    guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
        return nil
    }
    metalLibraryValue = (device, library)
    return library
}

// The effect's pipelines, made once per process. Compiling them takes about 200 ms when the system's shader cache
// misses, so they are made in the background (`prewarmDustEffect`) before a message can be deleted.
final class DustEffectPipelines {
    static let shared = DustEffectPipelines()

    private let lock = NSLock()
    private var renderPipelineState: MTLRenderPipelineState?
    private var computePipelines: DustEffectComputePipelines?
    private var isPrewarmStarted = false

    func prewarm(device: MTLDevice, qos: DispatchQoS.QoSClass) {
        self.lock.lock()
        let isStarted = self.isPrewarmStarted
        self.isPrewarmStarted = true
        self.lock.unlock()
        if isStarted {
            return
        }
        DispatchQueue.global(qos: qos).async {
            let _ = self.compute(device: device)
            let _ = self.render(device: device)
        }
    }

    // Compiles on the calling thread if the pipeline is not ready yet. Two threads may both compile it; the first
    // result is kept.
    func render(device: MTLDevice) -> MTLRenderPipelineState? {
        self.lock.lock()
        let cached = self.renderPipelineState
        self.lock.unlock()
        if let cached {
            return cached
        }
        guard let library = metalLibrary(device: device), let descriptor = DustEffectRenderPipeline.descriptor(library: library) else {
            return nil
        }
        guard let pipelineState = MetalEngine.shared.pipelineCache.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let current = self.renderPipelineState {
            return current
        }
        self.renderPipelineState = pipelineState
        return pipelineState
    }

    func compute(device: MTLDevice) -> DustEffectComputePipelines? {
        self.lock.lock()
        let cached = self.computePipelines
        self.lock.unlock()
        if let cached {
            return cached
        }
        guard let library = metalLibrary(device: device) else {
            return nil
        }
        guard let pipelines = DustEffectComputePipelines(library: library, makePipelineState: { function in
            return MetalEngine.shared.pipelineCache.makeComputePipelineState(function: function)
        }) else {
            return nil
        }
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let current = self.computePipelines {
            return current
        }
        self.computePipelines = pipelines
        return pipelines
    }
}

// Makes the dust effect's pipelines in the background, once per process: when a message menu opens or selection
// starts (a delete may follow), and at a lower priority when a chat first appears (auto-deleted messages).
public func prewarmDustEffect(qos: DispatchQoS.QoSClass = .userInitiated) {
    DustEffectPipelines.shared.prewarm(device: MetalEngine.shared.device, qos: qos)
}
