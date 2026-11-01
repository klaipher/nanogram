import Foundation
import UIKit
import Metal
import MetalKit
import simd
import DctHuffman
import MetalImageView

private struct Vertex {
    var position: vector_float2
    var textureCoordinate: vector_float2
}

public final class CompressedImageRenderer {
    private final class Shared {
        static let shared: Shared = {
            return Shared(sharedContext: AnimationCompressor.SharedContext.shared)!
        }()
        
        let sharedContext: AnimationCompressor.SharedContext
        
        let computeIdctPipelineState: MTLComputePipelineState
        let renderIdctPipelineState: MTLRenderPipelineState
        let renderRgbPipelineState: MTLRenderPipelineState
        let renderYuvaPipelineState: MTLRenderPipelineState
        
        init?(sharedContext: AnimationCompressor.SharedContext) {
            self.sharedContext = sharedContext
            
            guard let idctFunction = self.sharedContext.defaultLibrary.makeFunction(name: "idctKernel") else {
                return nil
            }
            
            guard let computeIdctPipelineState = try? self.sharedContext.device.makeComputePipelineState(function: idctFunction) else {
                return nil
            }
            self.computeIdctPipelineState = computeIdctPipelineState
            
            guard let vertexShader = self.sharedContext.defaultLibrary.makeFunction(name: "vertexShader") else {
                return nil
            }
            guard let samplingIdctShader = self.sharedContext.defaultLibrary.makeFunction(name: "samplingIdctShader") else {
                return nil
            }
            guard let samplingRgbShader = self.sharedContext.defaultLibrary.makeFunction(name: "samplingRgbShader") else {
                return nil
            }
            guard let samplingYuvaShader = self.sharedContext.defaultLibrary.makeFunction(name: "samplingYuvaShader") else {
                return nil
            }
            
            let idctPipelineStateDescriptor = MTLRenderPipelineDescriptor()
            idctPipelineStateDescriptor.label = "Render IDCT Pipeline"
            idctPipelineStateDescriptor.vertexFunction = vertexShader
            idctPipelineStateDescriptor.fragmentFunction = samplingIdctShader
            idctPipelineStateDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            guard let renderIdctPipelineState = try? self.sharedContext.device.makeRenderPipelineState(descriptor: idctPipelineStateDescriptor) else {
                return nil
            }
            self.renderIdctPipelineState = renderIdctPipelineState
            
            let rgbPipelineStateDescriptor = MTLRenderPipelineDescriptor()
            rgbPipelineStateDescriptor.label = "Render RGB Pipeline"
            rgbPipelineStateDescriptor.vertexFunction = vertexShader
            rgbPipelineStateDescriptor.fragmentFunction = samplingRgbShader
            rgbPipelineStateDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            guard let renderRgbPipelineState = try? self.sharedContext.device.makeRenderPipelineState(descriptor: rgbPipelineStateDescriptor) else {
                return nil
            }
            self.renderRgbPipelineState = renderRgbPipelineState
            
            let yuvaPipelineStateDescriptor = MTLRenderPipelineDescriptor()
            yuvaPipelineStateDescriptor.label = "Render YUVA Pipeline"
            yuvaPipelineStateDescriptor.vertexFunction = vertexShader
            yuvaPipelineStateDescriptor.fragmentFunction = samplingYuvaShader
            yuvaPipelineStateDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            guard let renderYuvaPipelineState = try? self.sharedContext.device.makeRenderPipelineState(descriptor: yuvaPipelineStateDescriptor) else {
                return nil
            }
            self.renderYuvaPipelineState = renderYuvaPipelineState
        }
    }
    
    /// Upload textures a frame owns from the moment the CPU writes them until its command buffer
    /// completes. Frames are rendered without waiting for the previous one, so a single texture was
    /// rewritten (on a global queue, by several frames at once) while the GPU still read it.
    private final class UploadPool<T: AnyObject> {
        private let lock = NSLock()
        private var free: [T] = []
        private var inFlight = 0
        private let limit: Int
        
        init(limit: Int) {
            self.limit = limit
        }
        
        /// Nil when `limit` frames are already in flight or a texture cannot be made: the frame is dropped.
        func take(isReusable: (T) -> Bool, make: () -> T?) -> T? {
            self.lock.lock()
            if self.inFlight >= self.limit {
                self.lock.unlock()
                return nil
            }
            self.free.removeAll(where: { !isReusable($0) })
            let reused = self.free.popLast()
            self.inFlight += 1
            self.lock.unlock()
            
            if let reused {
                return reused
            }
            if let made = make() {
                return made
            }
            self.lock.lock()
            self.inFlight -= 1
            self.lock.unlock()
            return nil
        }
        
        func put(_ item: T) {
            self.lock.lock()
            self.inFlight -= 1
            self.free.append(item)
            self.lock.unlock()
        }
        
        func removeFree() {
            self.lock.lock()
            self.free.removeAll()
            self.lock.unlock()
        }
    }
    
    private static let maxFramesInFlight = 3
    
    private let sharedContext: AnimationCompressor.SharedContext
    private let shared: Shared
    
    private let compressedTexturePool = UploadPool<TextureSet>(limit: CompressedImageRenderer.maxFramesInFlight)
    private let rgbTexturePool = UploadPool<Texture>(limit: CompressedImageRenderer.maxFramesInFlight)
    private let yuvaTexturePool = UploadPool<TextureSet>(limit: CompressedImageRenderer.maxFramesInFlight)
    
    // Written by the IDCT kernel and read by the render pass of the same command buffer; command
    // buffers of one queue are ordered, so frames can share it. Main queue only.
    private var outputTextures: TextureSet?
    
    private let commandQueue: MTLCommandQueue
    
    // CPU-side decoding and uploads, one frame at a time.
    private let uploadQueue = DispatchQueue(label: "org.telegram.CompressedImageRenderer.upload", qos: .userInitiated)
    
    public init?(sharedContext: AnimationCompressor.SharedContext) {
        self.sharedContext = sharedContext
        self.shared = Shared.shared
        
        guard let commandQueue = self.sharedContext.device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = commandQueue
    }
    
    // Main queue only: MetalImageLayer's renderer is not thread-safe.
    private func getNextDrawable(layer: MetalImageLayer, drawableSize: CGSize) -> MetalImageLayer.Drawable? {
        layer.renderer.drawableSize = drawableSize
        return layer.renderer.nextDrawable()
    }
    
    /// Writes `source` (rows of `rowLength` bytes, `bytesPerRow` apart) into `texture`.
    private static func upload(_ source: UnsafeRawPointer, rowLength: Int, height: Int, bytesPerRow: Int, to texture: Texture) {
        if let directBuffer = texture.directBuffer {
            let destination = directBuffer.buffer.contents()
            if directBuffer.bytesPerRow == bytesPerRow {
                memcpy(destination, source, bytesPerRow * height)
            } else {
                for y in 0 ..< height {
                    memcpy(destination.advanced(by: y * directBuffer.bytesPerRow), source.advanced(by: y * bytesPerRow), rowLength)
                }
            }
        } else {
            let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: texture.width, height: texture.height, depth: 1))
            texture.texture.replace(region: region, mipmapLevel: 0, withBytes: source, bytesPerRow: bytesPerRow)
        }
    }
    
    /// Huffman-decodes a plane into its coefficient texture.
    private static func upload(plane: CompressedImageLayout.Plane, to texture: Texture) {
        // Sizes come from a validated CompressedImageLayout: at most 4096 pixels wide.
        let width = Int32(clamping: plane.width)
        let height = Int32(clamping: plane.height)
        if let directBuffer = texture.directBuffer, directBuffer.bytesPerRow % 4 == 0 {
            readDCTBlocks(width, height, plane.data, directBuffer.buffer.contents().assumingMemoryBound(to: Float32.self), Int32(clamping: directBuffer.bytesPerRow / 4))
        } else {
            var coefficients = Data(count: plane.bytesPerRow * plane.height)
            coefficients.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                readDCTBlocks(width, height, plane.data, baseAddress.assumingMemoryBound(to: Float32.self), Int32(clamping: plane.bytesPerRow / 4))
                let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: plane.width, height: plane.height, depth: 1))
                texture.texture.replace(region: region, mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: plane.bytesPerRow)
            }
        }
    }
    
    private func uploadIdctTextures(layout: CompressedImageLayout) -> TextureSet? {
        let device = self.sharedContext.device
        guard let compressedTextures = self.compressedTexturePool.take(isReusable: { $0.width == layout.width && $0.height == layout.height }, make: {
            return TextureSet(
                device: device,
                width: layout.width,
                height: layout.height,
                descriptions: [
                    TextureSet.Description(
                        fractionWidth: 1, fractionHeight: 1,
                        pixelFormat: .r32Float
                    ),
                    TextureSet.Description(
                        fractionWidth: 2, fractionHeight: 2,
                        pixelFormat: .r32Float
                    ),
                    TextureSet.Description(
                        fractionWidth: 2, fractionHeight: 2,
                        pixelFormat: .r32Float
                    ),
                    TextureSet.Description(
                        fractionWidth: 1, fractionHeight: 1,
                        pixelFormat: .r32Float
                    )
                ],
                usage: .shaderRead,
                isShared: true
            )
        }) else {
            return nil
        }
        
        for i in 0 ..< 4 {
            CompressedImageRenderer.upload(plane: layout.planes[i], to: compressedTextures.textures[i])
        }
        return compressedTextures
    }
    
    public func renderIdct(layer: MetalImageLayer, compressedImage: AnimationCompressor.CompressedImageData, completion: @escaping () -> Void) {
        self.uploadQueue.async {
            // A frame read from the cache file: its sizes decide what is written where, so a frame
            // that does not describe whole blocks of this format is not drawn.
            guard let layout = CompressedImageLayout(data: compressedImage.data), let compressedTextures = self.uploadIdctTextures(layout: layout) else {
                DispatchQueue.main.async {
                    completion()
                }
                return
            }
            
            DispatchQueue.main.async {
                self.encodeIdct(layer: layer, compressedTextures: compressedTextures, completion: completion)
            }
        }
    }
    
    private func encodeIdct(layer: MetalImageLayer, compressedTextures: TextureSet, completion: @escaping () -> Void) {
        let compressedTexturePool = self.compressedTexturePool
        let fail = {
            compressedTexturePool.put(compressedTextures)
            completion()
        }
        
        let outputTextures: TextureSet
        if let current = self.outputTextures, current.width == compressedTextures.width, current.height == compressedTextures.height {
            outputTextures = current
        } else {
            guard let textures = TextureSet(
                device: self.sharedContext.device,
                width: compressedTextures.width,
                height: compressedTextures.height,
                descriptions: [
                    TextureSet.Description(
                        fractionWidth: 1, fractionHeight: 1,
                        pixelFormat: .r8Unorm
                    ),
                    TextureSet.Description(
                        fractionWidth: 2, fractionHeight: 2,
                        pixelFormat: .r8Unorm
                    ),
                    TextureSet.Description(
                        fractionWidth: 2, fractionHeight: 2,
                        pixelFormat: .r8Unorm
                    ),
                    TextureSet.Description(
                        fractionWidth: 1, fractionHeight: 1,
                        pixelFormat: .r8Unorm
                    )
                ],
                usage: [.shaderRead, .shaderWrite],
                isShared: false
            ) else {
                fail()
                return
            }
            self.outputTextures = textures
            outputTextures = textures
        }
        
        let drawableSize = CGSize(width: CGFloat(outputTextures.textures[0].width), height: CGFloat(outputTextures.textures[0].height))
        guard let drawable = self.getNextDrawable(layer: layer, drawableSize: drawableSize) else {
            fail()
            return
        }
        
        guard let commandBuffer = self.commandQueue.makeCommandBuffer() else {
            fail()
            return
        }
        commandBuffer.label = "MyCommand"
        
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            fail()
            return
        }
        
        computeEncoder.setComputePipelineState(self.shared.computeIdctPipelineState)
        
        for i in 0 ..< 4 {
            computeEncoder.setTexture(compressedTextures.textures[i].texture, index: 0)
            computeEncoder.setTexture(outputTextures.textures[i].texture, index: 1)
            
            var colorPlaneInt32 = Int32(clamping: i)
            computeEncoder.setBytes(&colorPlaneInt32, length: 4, index: 2)
            
            let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
            let threadgroupCount = MTLSize(width: (compressedTextures.textures[i].width + threadgroupSize.width - 1) / threadgroupSize.width, height: (compressedTextures.textures[i].height + threadgroupSize.height - 1) / threadgroupSize.height, depth: 1)
            
            computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        }
        
        computeEncoder.endEncoding()
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            // The compute pass is encoded: let it run before the textures are reused.
            commandBuffer.addCompletedHandler { _ in
                compressedTexturePool.put(compressedTextures)
            }
            commandBuffer.commit()
            completion()
            return
        }
        renderEncoder.label = "MyRenderEncoder"
        
        renderEncoder.setRenderPipelineState(self.shared.renderIdctPipelineState)
        
        for i in 0 ..< 4 {
            renderEncoder.setFragmentTexture(outputTextures.textures[i].texture, index: i)
        }
        
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        
        renderEncoder.endEncoding()
        
        self.commit(commandBuffer: commandBuffer, drawable: drawable, completion: completion, release: {
            compressedTexturePool.put(compressedTextures)
        })
    }
    
    /// Commits and presents the drawable once the GPU is done. `release` returns the frame's upload
    /// textures; a failed command buffer presents nothing.
    private func commit(commandBuffer: MTLCommandBuffer, drawable: MetalImageLayer.Drawable, completion: @escaping () -> Void, release: @escaping () -> Void) {
        var storedDrawable: MetalImageLayer.Drawable? = drawable
        commandBuffer.addCompletedHandler { commandBuffer in
            release()
            let succeeded = commandBuffer.status == .completed && commandBuffer.error == nil
            DispatchQueue.main.async {
                autoreleasepool {
                    if succeeded, let drawable = storedDrawable {
                        drawable.present(completion: completion)
                    } else {
                        completion()
                    }
                    storedDrawable = nil
                }
            }
        }
        commandBuffer.commit()
    }
    
    /// Draws a BGRA frame. `multiplyAlpha`: the frame is not premultiplied (decoded video).
    public func renderRgb(layer: MetalImageLayer, width: Int, height: Int, bytesPerRow: Int, data: Data, multiplyAlpha: Bool, completion: @escaping () -> Void) {
        guard width > 0, height > 0, bytesPerRow >= width * 4, data.count >= bytesPerRow * height else {
            completion()
            return
        }
        
        let device = self.sharedContext.device
        guard let rgbTexture = self.rgbTexturePool.take(isReusable: { $0.width == width && $0.height == height }, make: {
            return Texture(device: device, width: width, height: height, pixelFormat: .bgra8Unorm, usage: .shaderRead, isShared: true)
        }) else {
            completion()
            return
        }
        let rgbTexturePool = self.rgbTexturePool
        let fail = {
            rgbTexturePool.put(rgbTexture)
            completion()
        }
        
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            CompressedImageRenderer.upload(baseAddress, rowLength: width * 4, height: height, bytesPerRow: bytesPerRow, to: rgbTexture)
        }
        
        let drawableSize = CGSize(width: CGFloat(rgbTexture.width), height: CGFloat(rgbTexture.height))
        guard let drawable = self.getNextDrawable(layer: layer, drawableSize: drawableSize) else {
            fail()
            return
        }
        
        guard let commandBuffer = self.commandQueue.makeCommandBuffer() else {
            fail()
            return
        }
        commandBuffer.label = "MyCommand"

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fail()
            return
        }
        renderEncoder.label = "MyRenderEncoder"
        
        renderEncoder.setRenderPipelineState(self.shared.renderRgbPipelineState)
        renderEncoder.setFragmentTexture(rgbTexture.texture, index: 0)
        var multiplyAlphaValue: UInt32 = multiplyAlpha ? 1 : 0
        renderEncoder.setFragmentBytes(&multiplyAlphaValue, length: 4, index: 0)
        
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        
        renderEncoder.endEncoding()
        
        self.commit(commandBuffer: commandBuffer, drawable: drawable, completion: completion, release: {
            rgbTexturePool.put(rgbTexture)
        })
    }
    
    private func uploadYuvaTextures(width: Int, height: Int, data: Data) -> TextureSet? {
        // Y at full size, interleaved CbCr at half size, alpha packed two pixels per byte.
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0, data.count >= width * height * 2 else {
            return nil
        }
        
        let device = self.sharedContext.device
        guard let yuvaTextures = self.yuvaTexturePool.take(isReusable: { $0.width == width && $0.height == height }, make: {
            return TextureSet(
                device: device,
                width: width,
                height: height,
                descriptions: [
                    TextureSet.Description(
                        fractionWidth: 1, fractionHeight: 1,
                        pixelFormat: .r8Unorm
                    ),
                    TextureSet.Description(
                        fractionWidth: 2, fractionHeight: 2,
                        pixelFormat: .rg8Unorm
                    ),
                    TextureSet.Description(
                        fractionWidth: 2, fractionHeight: 1,
                        pixelFormat: .r8Uint
                    )
                ],
                usage: .shaderRead,
                isShared: true
            )
        }) else {
            return nil
        }
        
        data.withUnsafeBytes { yuvaBuffer in
            guard let yuva = yuvaBuffer.baseAddress else {
                return
            }
            CompressedImageRenderer.upload(yuva, rowLength: width, height: height, bytesPerRow: width, to: yuvaTextures.textures[0])
            CompressedImageRenderer.upload(yuva.advanced(by: width * height), rowLength: width, height: height / 2, bytesPerRow: width, to: yuvaTextures.textures[1])
            CompressedImageRenderer.upload(yuva.advanced(by: width * height * 2 - width / 2 * height), rowLength: width / 2, height: height, bytesPerRow: width / 2, to: yuvaTextures.textures[2])
        }
        return yuvaTextures
    }
    
    public func renderYuva(layer: MetalImageLayer, width: Int, height: Int, data: Data, completion: @escaping () -> Void) {
        self.uploadQueue.async {
            guard let yuvaTextures = self.uploadYuvaTextures(width: width, height: height, data: data) else {
                DispatchQueue.main.async {
                    completion()
                }
                return
            }
            
            DispatchQueue.main.async {
                self.encodeYuva(layer: layer, yuvaTextures: yuvaTextures, completion: completion)
            }
        }
    }
    
    private func encodeYuva(layer: MetalImageLayer, yuvaTextures: TextureSet, completion: @escaping () -> Void) {
        let yuvaTexturePool = self.yuvaTexturePool
        let fail = {
            yuvaTexturePool.put(yuvaTextures)
            completion()
        }
        
        let drawableSize = CGSize(width: CGFloat(yuvaTextures.width), height: CGFloat(yuvaTextures.height))
        guard let drawable = self.getNextDrawable(layer: layer, drawableSize: drawableSize) else {
            fail()
            return
        }
        
        guard let commandBuffer = self.commandQueue.makeCommandBuffer() else {
            fail()
            return
        }
        commandBuffer.label = "MyCommand"
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fail()
            return
        }
        renderEncoder.label = "MyRenderEncoder"
        
        renderEncoder.setRenderPipelineState(self.shared.renderYuvaPipelineState)
        renderEncoder.setFragmentTexture(yuvaTextures.textures[0].texture, index: 0)
        renderEncoder.setFragmentTexture(yuvaTextures.textures[1].texture, index: 1)
        renderEncoder.setFragmentTexture(yuvaTextures.textures[2].texture, index: 2)
        
        var alphaSize = simd_uint2(UInt32(clamping: yuvaTextures.textures[0].texture.width), UInt32(clamping: yuvaTextures.textures[0].texture.height))
        renderEncoder.setFragmentBytes(&alphaSize, length: 8, index: 3)
        
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        
        renderEncoder.endEncoding()
        
        self.commit(commandBuffer: commandBuffer, drawable: drawable, completion: completion, release: {
            yuvaTexturePool.put(yuvaTextures)
        })
    }
}
