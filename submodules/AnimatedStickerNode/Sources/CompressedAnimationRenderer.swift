import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import YuvConversion
import Accelerate
import AnimationCompression
import Metal
import MetalKit
import MetalImageView

enum CompressedAnimationYuvaDrawing: Equatable {
    /// Uploaded as planes and converted by the YUVA shader.
    case planes
    /// Decoded on the CPU, as `SoftwareAnimationRenderer` does, and drawn as BGRA: odd sizes,
    /// whose chroma and alpha rows the shader's textures do not describe.
    case decodedBgra
    /// Too short for its size: not drawn.
    case none
}

/// How `CompressedAnimationRenderer` draws a YUVA frame from the CPU caches.
func compressedAnimationYuvaDrawing(width: Int, height: Int, dataCount: Int) -> CompressedAnimationYuvaDrawing {
    if YuvaFrameLayout(width: width, height: height, dataCount: dataCount) != nil {
        return .planes
    }
    if width > 0, height > 0, width <= 4096, height <= 4096, dataCount >= YuvaFrameLayout.length(width: width, height: height) {
        return .decodedBgra
    }
    return .none
}

@available(iOS 10.0, *)
final class CompressedAnimationRenderer: ASDisplayNode, AnimationRenderer {
    private final class View: UIView {
        static override var layerClass: AnyClass {
            return MetalImageLayer.self
        }

        init(device: MTLDevice) {
            super.init(frame: CGRect())
            
            (self.layer as! MetalImageLayer).renderer.device = device
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
        }
    }
    
    private var highlightedContentNode: ASDisplayNode?
    private var highlightedColor: UIColor?
    private var highlightReplacesContent = false
    
    private let renderer: CompressedImageRenderer
    
    var currentFrameImage: UIImage? {
        return nil
    }
    
    override init() {
        self.renderer = CompressedImageRenderer(sharedContext: AnimationCompressor.SharedContext.shared)!
        
        super.init()
        
        self.setViewBlock({
            return View(device: AnimationCompressor.SharedContext.shared.device)
        })
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.layer.isOpaque = false
        self.layer.backgroundColor = nil
    }
        
    func render(queue: Queue, width: Int, height: Int, bytesPerRow: Int, data: Data, type: AnimationRendererFrameType, mulAlpha: Bool, completion: @escaping () -> Void, averageColor: ((UIColor) -> Void)?) {
        guard let layer = self.layer as? MetalImageLayer else {
            completion()
            return
        }
        switch type {
        case .dct:
            self.renderer.renderIdct(layer: layer, compressedImage: AnimationCompressor.CompressedImageData(data: data), completion: { [weak self] in
                self?.updateHighlightedContentNode()
                completion()
            })
        case .argb:
            self.renderer.renderRgb(layer: layer, width: width, height: height, bytesPerRow: bytesPerRow, data: data, multiplyAlpha: mulAlpha, completion: { [weak self] in
                self?.updateHighlightedContentNode()
                completion()
            })
        case .yuva:
            switch compressedAnimationYuvaDrawing(width: width, height: height, dataCount: data.count) {
            case .planes:
                self.renderer.renderYuva(layer: layer, width: width, height: height, data: data, completion: { [weak self] in
                    self?.updateHighlightedContentNode()
                    completion()
                })
            case .decodedBgra:
                // Decoded as SoftwareAnimationRenderer does: premultiplied BGRA.
                queue.async { [weak self] in
                    let bytesPerRow = width * 4
                    var bgra = Data(count: bytesPerRow * height)
                    bgra.withUnsafeMutableBytes { dest in
                        data.withUnsafeBytes { source in
                            guard let destAddress = dest.baseAddress, let sourceAddress = source.baseAddress else {
                                return
                            }
                            decodeYUVAToRGBA(sourceAddress.assumingMemoryBound(to: UInt8.self), destAddress.assumingMemoryBound(to: UInt8.self), Int32(clamping: width), Int32(clamping: height), Int32(clamping: bytesPerRow))
                        }
                    }
                    Queue.mainQueue().async {
                        guard let self, let layer = self.layer as? MetalImageLayer else {
                            completion()
                            return
                        }
                        self.renderer.renderRgb(layer: layer, width: width, height: height, bytesPerRow: bytesPerRow, data: bgra, multiplyAlpha: false, completion: { [weak self] in
                            self?.updateHighlightedContentNode()
                            completion()
                        })
                    }
                }
            case .none:
                completion()
            }
        }
    }
    
    private func updateHighlightedContentNode() {
        guard let highlightedContentNode = self.highlightedContentNode, let highlightedColor = self.highlightedColor else {
            return
        }
        if let contents = self.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
            (highlightedContentNode.view as! UIImageView).image = UIImage(cgImage: contents as! CGImage).withRenderingMode(.alwaysTemplate)
        }
        highlightedContentNode.tintColor = highlightedColor
        if self.highlightReplacesContent {
            self.contents = nil
        }
    }
            
    func setOverlayColor(_ color: UIColor?, replace: Bool, animated: Bool) {
        self.highlightReplacesContent = replace
        var updated = false
        if let current = self.highlightedColor, let color = color {
            updated = !current.isEqual(color)
        } else if (self.highlightedColor != nil) != (color != nil) {
            updated = true
        }
        
        if !updated {
            return
        }
        
        self.highlightedColor = color
        
        if let _ = color {
            if let highlightedContentNode = self.highlightedContentNode {
                highlightedContentNode.alpha = 1.0
            } else {
                let highlightedContentNode = ASDisplayNode(viewBlock: {
                    return makeAnimationRendererImageView()
                }, didLoad: nil)
                highlightedContentNode.displaysAsynchronously = false
                
                self.highlightedContentNode = highlightedContentNode
                highlightedContentNode.frame = self.bounds
                self.addSubnode(highlightedContentNode)
            }
            self.updateHighlightedContentNode()
        } else if let highlightedContentNode = self.highlightedContentNode {
            highlightedContentNode.alpha = 0.0
            highlightedContentNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, completion: { [weak self] completed in
                guard let strongSelf = self, completed else {
                    return
                }
                strongSelf.highlightedContentNode?.removeFromSupernode()
                strongSelf.highlightedContentNode = nil
            })
        }
    }
}
