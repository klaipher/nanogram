import Foundation
import UIKit
import Display
import BatchVideoRendering
import AccountContext
import TelegramCore
import AVFoundation
import SwiftSignalKit
import PhotoResources

open class GifVideoLayer: AVSampleBufferDisplayLayer, BatchVideoRenderingContext.Target {
    private let context: AccountContext
    private let batchVideoContext: BatchVideoRenderingContext
    private let userLocation: MediaResourceUserLocation
    private let file: FileMediaReference?
    
    private var batchVideoTargetHandle: BatchVideoRenderingContext.TargetHandle?
    public var batchVideoRenderingTargetState: BatchVideoRenderingContext.TargetState?
    
    private var thumbnailDisposable: Disposable?
    private var thumbnailGeneration: Int = 0
    private var appliedThumbnailGeneration: Int = 0
    
    private var isReadyToRender: Bool = false
    
    public var started: (() -> Void)?
    
    public var shouldBeAnimating: Bool = false {
        didSet {
            if self.shouldBeAnimating == oldValue {
                return
            }
            self.updateShouldBeRendering()
        }
    }
    
    public init(context: AccountContext, batchVideoContext: BatchVideoRenderingContext, userLocation: MediaResourceUserLocation, file: FileMediaReference?, synchronousLoad: Bool, synchronousLoadOnlyFromCache: Bool = false) {
        self.context = context
        self.batchVideoContext = batchVideoContext
        self.userLocation = userLocation
        self.file = file
        
        super.init()
        
        self.videoGravity = .resizeAspectFill
        
        if let file = self.file {
            if let dimensions = file.media.dimensions {
                let cacheKey = GifThumbnailCache.key(namespace: file.media.fileId.namespace, id: file.media.fileId.id, width: 93, height: 93)
                let cachedImage = synchronousLoad && synchronousLoadOnlyFromCache ? GifThumbnailCache.shared.image(forKey: cacheKey) : nil
                let plan = GifThumbnailCache.plan(isCached: cachedImage != nil, synchronousLoadRequested: synchronousLoad, synchronousOnlyFromCache: synchronousLoadOnlyFromCache)
                if plan == .applyCachedNow, let cachedImage {
                    // A picture decoded earlier: no read and no draw on the main thread. The load below
                    // still runs off main and replaces it if a better one arrives.
                    self.contents = cachedImage
                    self.setupVideo()
                }
                self.thumbnailDisposable = (mediaGridMessageVideo(postbox: context.account.postbox, userLocation: userLocation, videoReference: file, synchronousLoad: plan == .loadOnMain, nilForEmptyResult: true)
                |> deliverOnMainQueue).start(next: { [weak self] transform in
                    guard let strongSelf = self else {
                        return
                    }
                    let boundingSize = CGSize(width: 93.0, height: 93.0)
                    let imageSize = dimensions.cgSize.aspectFilled(boundingSize)
                    let arguments = TransformImageArguments(corners: ImageCorners(), imageSize: imageSize, boundingSize: boundingSize, intrinsicInsets: UIEdgeInsets(), resizeMode: .fill(.clear))
                    
                    if plan == .loadOnMain {
                        if let image = transform(arguments)?.generateImage() {
                            Queue.mainQueue().async {
                                if let strongSelf = self {
                                    strongSelf.contents = image.cgImage
                                    strongSelf.setupVideo()
                                    strongSelf.started?()
                                }
                            }
                        } else {
                            strongSelf.setupVideo()
                        }
                    } else {
                        // Decode and draw the thumbnail off the main thread; only the layer
                        // update happens on main. An image older than the one already shown is
                        // dropped so a slow decode cannot overwrite a newer thumbnail; until the
                        // newer one is ready the older one still shows, as it did before.
                        strongSelf.thumbnailGeneration += 1
                        let generation = strongSelf.thumbnailGeneration
                        Queue.concurrentDefaultQueue().async {
                            let image = transform(arguments)?.generateImage()
                            if let cgImage = image?.cgImage {
                                GifThumbnailCache.shared.store(cgImage, forKey: cacheKey)
                            }
                            Queue.mainQueue().async {
                                guard let strongSelf = self, generation > strongSelf.appliedThumbnailGeneration else {
                                    return
                                }
                                if let image {
                                    strongSelf.appliedThumbnailGeneration = generation
                                    strongSelf.contents = image.cgImage
                                    strongSelf.setupVideo()
                                    strongSelf.started?()
                                } else {
                                    strongSelf.setupVideo()
                                }
                            }
                        }
                    }
                })
            } else {
                self.setupVideo()
            }
        }
    }
    
    override public init(layer: Any) {
        guard let layer = layer as? GifVideoLayer else {
            preconditionFailure()
        }
        
        self.context = layer.context
        self.batchVideoContext = layer.batchVideoContext
        self.userLocation = layer.userLocation
        self.file = layer.file
        
        super.init(layer: layer)
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.thumbnailDisposable?.dispose()
    }
    
    private func setupVideo() {
        self.isReadyToRender = true
        self.updateShouldBeRendering()
    }
    
    private func updateShouldBeRendering() {
        let shouldBeRendering = self.shouldBeAnimating && self.isReadyToRender
        
        if shouldBeRendering, let file = self.file {
            if self.batchVideoTargetHandle == nil {
                self.batchVideoTargetHandle = self.batchVideoContext.add(target: self, file: file, userLocation: self.userLocation)
            }
        } else {
            self.batchVideoTargetHandle = nil
        }
    }
    
    public func setSampleBuffer(sampleBuffer: CMSampleBuffer) {
        if #available(iOS 17.0, *) {
            self.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            self.enqueue(sampleBuffer)
        }
    }
}
