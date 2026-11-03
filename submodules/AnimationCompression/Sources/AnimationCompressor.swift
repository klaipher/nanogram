import Foundation
import Metal
import DctHuffman

private final class BundleHelper: NSObject {
}

private func alignUp(size: Int, align: Int) -> Int {
    precondition(((align - 1) & align) == 0, "Align must be a power of two")

    let alignmentMask = align - 1
    return (size + alignmentMask) & ~alignmentMask
}

final class Texture {
    final class DirectBuffer {
        let buffer: MTLBuffer
        let bytesPerRow: Int
        
        init?(device: MTLDevice, width: Int, height: Int, bytesPerRow: Int) {
            #if targetEnvironment(simulator)
            return nil
            #else
            if #available(iOS 12.0, *) {
                let pagesize = Int(getpagesize())
                let allocationSize = alignUp(size: bytesPerRow * height, align: pagesize)
                var data: UnsafeMutableRawPointer? = nil
                let result = posix_memalign(&data, pagesize, allocationSize)
                if result == noErr, let data = data {
                    self.bytesPerRow = bytesPerRow
                    
                    guard let buffer = device.makeBuffer(
                        bytesNoCopy: data,
                        length: allocationSize,
                        options: .storageModeShared,
                        deallocator: { _, _ in
                            free(data)
                        }
                    ) else {
                        return nil
                    }
                    
                    self.buffer = buffer
                } else {
                    return nil
                }
            } else {
                return nil
            }
            #endif
        }
    }
    
    let width: Int
    let height: Int
    let texture: MTLTexture
    
    let directBuffer: DirectBuffer?
    
    init?(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage,
        isShared: Bool
    ) {
        self.width = width
        self.height = height
        
        if #available(iOS 12.0, *), isShared, usage.contains(.shaderRead) {
            switch pixelFormat {
            case .r32Float, .bgra8Unorm:
                let bytesPerPixel = 4
                let pixelRowAlignment = device.minimumTextureBufferAlignment(for: pixelFormat)
                let bytesPerRow = alignUp(size: width * bytesPerPixel, align: pixelRowAlignment)
                self.directBuffer = DirectBuffer(device: device, width: width, height: height, bytesPerRow: bytesPerRow)
            case .r8Unorm, .r8Uint:
                let bytesPerPixel = 1
                let pixelRowAlignment = device.minimumTextureBufferAlignment(for: pixelFormat)
                let bytesPerRow = alignUp(size: width * bytesPerPixel, align: pixelRowAlignment)
                self.directBuffer = DirectBuffer(device: device, width: width, height: height, bytesPerRow: bytesPerRow)
            case .rg8Unorm:
                let bytesPerPixel = 2
                let pixelRowAlignment = device.minimumTextureBufferAlignment(for: pixelFormat)
                let bytesPerRow = alignUp(size: width * bytesPerPixel, align: pixelRowAlignment)
                self.directBuffer = DirectBuffer(device: device, width: width, height: height, bytesPerRow: bytesPerRow)
            default:
                self.directBuffer = nil
            }
        } else {
            self.directBuffer = nil
        }
        
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.textureType = .type2D
        textureDescriptor.pixelFormat = pixelFormat
        textureDescriptor.width = width
        textureDescriptor.height = height
        textureDescriptor.usage = usage
        
        if let directBuffer = self.directBuffer {
            textureDescriptor.storageMode = directBuffer.buffer.storageMode
            guard let texture = directBuffer.buffer.makeTexture(descriptor: textureDescriptor, offset: 0, bytesPerRow: directBuffer.bytesPerRow) else {
                return nil
            }
            self.texture = texture
        } else {
            guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
                return nil
            }
            self.texture = texture
        }
    }
    
    func replace(with image: AnimationCompressor.ImageData) {
        if image.width != self.width || image.height != self.height {
            assert(false, "Image size does not match")
            return
        }
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: image.width, height: image.height, depth: 1))
        
        if let directBuffer = self.directBuffer, directBuffer.bytesPerRow == image.bytesPerRow {
            image.data.withUnsafeBytes { bytes in
                let _ = memcpy(directBuffer.buffer.contents(), bytes.baseAddress!, image.bytesPerRow * self.height)
            }
        } else {
            image.data.withUnsafeBytes { bytes in
                self.texture.replace(region: region, mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: image.bytesPerRow)
            }
        }
    }
    
    func readDirect(width: Int, height: Int, bytesPerRow: Int, read: (UnsafeMutableRawPointer?) -> UnsafeRawPointer) {
        if let directBuffer = self.directBuffer, width == self.width, height == self.height, bytesPerRow == directBuffer.bytesPerRow {
            let _ = read(directBuffer.buffer.contents())
        } else {
            let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height, depth: 1))
            self.texture.replace(region: region, mipmapLevel: 0, withBytes: read(nil), bytesPerRow: bytesPerRow)
        }
    }
}

final class TextureSet {
    struct Description {
        let fractionWidth: Int
        let fractionHeight: Int
        let pixelFormat: MTLPixelFormat
    }
    
    let width: Int
    let height: Int
    
    let textures: [Texture]
    
    init?(
        device: MTLDevice,
        width: Int,
        height: Int,
        descriptions: [Description],
        usage: MTLTextureUsage,
        isShared: Bool
    ) {
        self.width = width
        self.height = height
        
        var textures: [Texture] = []
        for i in 0 ..< descriptions.count {
            let planeWidth = width / descriptions[i].fractionWidth
            let planeHeight = height / descriptions[i].fractionHeight
            
            guard let texture = Texture(
                device: device,
                width: planeWidth,
                height: planeHeight,
                pixelFormat: descriptions[i].pixelFormat,
                usage: usage,
                isShared: isShared
            ) else {
                return nil
            }
            
            textures.append(texture)
        }
        
        self.textures = textures
    }
}

public final class AnimationCompressor {
    public final class ImageData {
        public let width: Int
        public let height: Int
        public let bytesPerRow: Int
        public let data: Data
        
        public init(width: Int, height: Int, bytesPerRow: Int, data: Data) {
            self.width = width
            self.height = height
            self.bytesPerRow = bytesPerRow
            self.data = data
        }
    }
    
    public final class CompressedImageData {
        public let data: Data
        
        public init(data: Data) {
            self.data = data
        }
    }
    
    public final class SharedContext {
        /// Nil where the process has no Metal device or the shader bundle is missing. Thread-safe.
        public static let sharedIfAvailable: SharedContext? = SharedContext()
        public static var shared: SharedContext {
            return SharedContext.sharedIfAvailable!
        }
        
        public let device: MTLDevice
        let defaultLibrary: MTLLibrary
        private let computeDctPipelineState: MTLComputePipelineState
        private let commandQueue: MTLCommandQueue
        
        public init?() {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return nil
            }
            self.device = device
            
            let mainBundle = Bundle(for: BundleHelper.self)

            guard let path = mainBundle.path(forResource: "AnimationCompressionBundle", ofType: "bundle") else {
                return nil
            }
            guard let bundle = Bundle(path: path) else {
                return nil
            }
            
            if #available(iOS 10.0, *) {
                guard let defaultLibrary = try? device.makeDefaultLibrary(bundle: bundle) else {
                    return nil
                }
                self.defaultLibrary = defaultLibrary
            } else {
                preconditionFailure()
            }
            
            guard let dctFunction = self.defaultLibrary.makeFunction(name: "dctKernel") else {
                return nil
            }
            
            guard let computeDctPipelineState = try? self.device.makeComputePipelineState(function: dctFunction) else {
                return nil
            }
            self.computeDctPipelineState = computeDctPipelineState
            
            guard let commandQueue = self.device.makeCommandQueue() else {
                return nil
            }
            self.commandQueue = commandQueue
        }
        
        func compress(compressor: AnimationCompressor, image: ImageData, completion: @escaping (CompressedImageData?) -> Void) {
            let fail = {
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
            
            guard AnimationCompressor.canCompress(width: image.width, height: image.height) else {
                fail()
                return
            }
            guard image.bytesPerRow >= image.width * 4, image.data.count >= image.bytesPerRow * image.height else {
                fail()
                return
            }
            
            // The frame owns its textures until its planes are read back. One set per compressor,
            // rewritten by the next frame while this one's planes were read back, gave read-backs
            // mixing two frames (frames queued on the main queue are issued back to back).
            guard let slot = compressor.takeSlot(device: self.device, width: image.width, height: image.height) else {
                fail()
                return
            }
            let inputTexture = slot.input
            let compressedTextures = slot.planes
            
            inputTexture.replace(with: image)
            
            guard let commandBuffer = self.commandQueue.makeCommandBuffer() else {
                compressor.returnSlot(slot)
                fail()
                return
            }
            commandBuffer.label = "ImageCompressor"
            
            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                compressor.returnSlot(slot)
                fail()
                return
            }
            computeEncoder.setComputePipelineState(self.computeDctPipelineState)
            
            computeEncoder.setTexture(inputTexture.texture, index: 0)
            
            let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
            for colorPlane in 0 ..< 4 {
                computeEncoder.setTexture(compressedTextures.textures[colorPlane].texture, index: 1)
                
                var colorPlaneInt32 = Int32(colorPlane)
                computeEncoder.setBytes(&colorPlaneInt32, length: 4, index: 2)
                
                let threadgroupCount = MTLSize(width: (compressedTextures.textures[colorPlane].width + threadgroupSize.width - 1) / threadgroupSize.width, height: (compressedTextures.textures[colorPlane].height + threadgroupSize.height - 1) / threadgroupSize.height, depth: 1)
                
                computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            }
            
            computeEncoder.endEncoding()
            
            commandBuffer.addCompletedHandler { [weak compressor] commandBuffer in
                // A command buffer that did not complete (an app in the background may not use the
                // GPU, a GPU timeout or reset) leaves the planes as they were: not this frame.
                guard commandBuffer.status == .completed, commandBuffer.error == nil else {
                    compressor?.returnSlot(slot)
                    fail()
                    return
                }
                
                var planeBytes: [Data] = []
                for i in 0 ..< 4 {
                    let plane = compressedTextures.textures[i]
                    let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: plane.width, height: plane.height, depth: 1))
                    let bytesPerRow = 4 * plane.width
                    var textureBytes = Data(count: bytesPerRow * plane.height)
                    textureBytes.withUnsafeMutableBytes { bytes in
                        guard let baseAddress = bytes.baseAddress else {
                            return
                        }
                        plane.texture.getBytes(baseAddress, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerRow * plane.height, from: region, mipmapLevel: 0, slice: 0)
                    }
                    planeBytes.append(textureBytes)
                }
                compressor?.returnSlot(slot)
                
                let buffer = WriteBuffer()
                
                buffer.writeInt32(CompressedImageLayout.magic)
                buffer.writeInt32(4)
                buffer.writeInt32(Int32(clamping: compressedTextures.textures[0].width))
                buffer.writeInt32(Int32(clamping: compressedTextures.textures[0].height))
                
                for i in 0 ..< 4 {
                    let plane = compressedTextures.textures[i]
                    let bytesPerRow = 4 * plane.width
                    
                    let huffmanData = planeBytes[i].withUnsafeBytes { bytes -> Data? in
                        guard let baseAddress = bytes.baseAddress else {
                            return nil
                        }
                        return writeDCTBlocks(Int32(clamping: plane.width), Int32(clamping: plane.height), baseAddress.assumingMemoryBound(to: Float32.self))
                    }
                    // nil: a coefficient the kernel cannot have produced. The frame is not cached.
                    guard let huffmanData else {
                        fail()
                        return
                    }
                    
                    buffer.writeInt32(Int32(clamping: plane.width))
                    buffer.writeInt32(Int32(clamping: plane.height))
                    buffer.writeInt32(Int32(clamping: bytesPerRow))
                    buffer.writeInt32(Int32(clamping: huffmanData.count))
                    buffer.write(huffmanData)
                }
                
                let data = buffer.makeData()
                DispatchQueue.main.async {
                    completion(CompressedImageData(data: data))
                }
            }
            
            commandBuffer.commit()
        }
    }
    
    /// Whether frames of this size can be DCT-compressed: whole 16x16 blocks, so that the half-size
    /// chroma planes are whole 8x8 blocks too. The sticker cache and the Metal renderer only use the
    /// DCT format for such sizes; any other size stays on the CPU path.
    public static func canCompress(width: Int, height: Int) -> Bool {
        return width > 0 && height > 0 && width % 16 == 0 && height % 16 == 0 && width <= maxDimension && height <= maxDimension
    }
    
    static let maxDimension = 4096
    
    /// The textures one frame uses from upload to read-back.
    final class FrameSlot {
        let input: Texture
        let planes: TextureSet
        
        init(input: Texture, planes: TextureSet) {
            self.input = input
            self.planes = planes
        }
    }
    
    /// More frames than this waiting for the GPU are dropped (not cached) rather than queued.
    static let maxFramesInFlight = 4
    
    private let slotsLock = NSLock()
    private var freeSlots: [FrameSlot] = []
    private var slotsInFlight = 0
    
    func takeSlot(device: MTLDevice, width: Int, height: Int) -> FrameSlot? {
        self.slotsLock.lock()
        if self.slotsInFlight >= AnimationCompressor.maxFramesInFlight {
            self.slotsLock.unlock()
            return nil
        }
        self.freeSlots.removeAll(where: { $0.input.width != width || $0.input.height != height })
        let reused = self.freeSlots.popLast()
        self.slotsInFlight += 1
        self.slotsLock.unlock()
        
        if let reused {
            return reused
        }
        
        guard let input = Texture(
            device: device,
            width: width,
            height: height,
            pixelFormat: .bgra8Unorm,
            usage: .shaderRead,
            isShared: true
        ), let planes = TextureSet(
            device: device,
            width: width,
            height: height,
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
            usage: [.shaderWrite],
            isShared: false
        ) else {
            self.slotsLock.lock()
            self.slotsInFlight -= 1
            self.slotsLock.unlock()
            return nil
        }
        return FrameSlot(input: input, planes: planes)
    }
    
    func returnSlot(_ slot: FrameSlot) {
        self.slotsLock.lock()
        self.slotsInFlight -= 1
        self.freeSlots.append(slot)
        self.slotsLock.unlock()
    }
    
    private let sharedContext: SharedContext
    
    public init(sharedContext: SharedContext) {
        self.sharedContext = sharedContext
    }
    
    /// Compresses one frame on the GPU. `completion` runs on the main queue, with nil when the frame
    /// was not compressed (a size `canCompress` rejects, too many frames in flight, a command
    /// buffer that failed, planes that are not DCT output); the caller keeps the frame uncached.
    public func compress(image: ImageData, completion: @escaping (CompressedImageData?) -> Void) {
        self.sharedContext.compress(compressor: self, image: image, completion: completion)
    }
}
