import Foundation
import UIKit
import Display
import UniversalMediaPlayer
import AccountContext
import SwiftSignalKit
import TelegramCore
import CoreMedia

public protocol BatchVideoRenderingContextTarget: AnyObject {
    var batchVideoRenderingTargetState: BatchVideoRenderingContext.TargetState? { get set }
    
    func setSampleBuffer(sampleBuffer: CMSampleBuffer)
}

public final class BatchVideoRenderingContext {
    public typealias Target = BatchVideoRenderingContextTarget
    
    public final class TargetHandle {
        private weak var context: BatchVideoRenderingContext?
        private let id: Int
        
        init(context: BatchVideoRenderingContext, id: Int) {
            self.context = context
            self.id = id
        }
        
        deinit {
            // The handle can be released on any queue; hop to main so the context's
            // non-thread-safe state (targetContexts, disposables, displayLink) is only
            // mutated from one queue.
            let context = self.context
            let id = self.id
            Queue.mainQueue().async {
                context?.targetRemoved(id: id)
            }
        }
    }
    
    public final class TargetState {
        private var lastRenderedFrame: (timestamp: Double, pts: Double, duration: Double)?
        private(set) var sampleBuffers: [CMSampleBuffer] = []
        
        init() {
        }
        
        func addSampleBuffers(sampleBuffers: [CMSampleBuffer]) {
            for sampleBuffer in sampleBuffers {
                self.sampleBuffers.append(sampleBuffer)
            }
        }
        
        func render(at timestamp: Double) -> CMSampleBuffer? {
            if !self.sampleBuffers.isEmpty {
                let sampleBuffer = self.sampleBuffers[0]
                let sampleBufferPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                let sampleBufferDuration = CMSampleBufferGetDuration(sampleBuffer).seconds
                if let lastRenderedFrame = self.lastRenderedFrame {
                    let elapsedTime = timestamp - lastRenderedFrame.timestamp
                    let ptsDifference = sampleBufferPts - lastRenderedFrame.pts
                    if ptsDifference < 0.0 {
                        // Loop
                        if elapsedTime >= lastRenderedFrame.duration {
                            self.lastRenderedFrame = (timestamp, sampleBufferPts, sampleBufferDuration)
                            self.sampleBuffers.removeFirst()
                            return sampleBuffer
                        } else {
                            return nil
                        }
                    } else {
                        if elapsedTime >= ptsDifference {
                            self.lastRenderedFrame = (timestamp, sampleBufferPts, sampleBufferDuration)
                            self.sampleBuffers.removeFirst()
                            return sampleBuffer
                        } else {
                            return nil
                        }
                    }
                } else {
                    self.lastRenderedFrame = (timestamp, sampleBufferPts, sampleBufferDuration)
                    self.sampleBuffers.removeFirst()
                    return sampleBuffer
                }
            } else {
                return nil
            }
        }
    }
    
    private final class ReadingContext {
        let dataPath: String
        
        var isFailed: Bool = false
        var reader: FFMpegFileReader?
        // Whether the *current* reader has produced at least one frame. A reader that reaches
        // `.endOfStream` without ever producing one describes a file this build cannot decode
        // — every frame decodes but `FFMpegMediaVideoFrameDecoder` rejects the pixel layout
        // (10-bit is the remaining class; the reported 4:4:4 case and 4:2:2 are now folded
        // down to 420 in the decoder). Restarting such a reader below would decode the
        // whole file again and never return from this call — pinning a core and leaving
        // `isRendering` stuck true, which freezes every other target sharing the queue.
        var readerDidProduceFrame: Bool = false
        // The current reader was rewound to loop instead of being opened again.
        var readerWasRewound: Bool = false
        // The current reader decodes with VideoToolbox and holds a slot of `hardwareReaders`.
        private var holdsHardwareSlot: Bool = false
        
        init(dataPath: String) {
            self.dataPath = dataPath
        }
        
        deinit {
            self.releaseReader()
        }
        
        private func releaseReader() {
            self.reader = nil
            if self.holdsHardwareSlot {
                self.holdsHardwareSlot = false
                BatchVideoRenderingContext.hardwareReaders.release()
            }
        }
        
        func advance() -> CMSampleBuffer? {
            outer: while true {
                if self.isFailed {
                    break outer
                }
                if self.reader == nil {
                    let hardwareSlot = BatchVideoRenderingContext.hardwareReaders.tryAcquire()
                    let reader = FFMpegFileReader(
                        source: .file(self.dataPath),
                        // VideoToolbox costs a flat ~75 us of CPU per frame and hands its buffer
                        // over without a copy; software decoding of a tiny clip costs less.
                        useHardwareAcceleration: hardwareSlot,
                        hardwareAccelerationMinimumLongSide: BatchVideoRenderingContext.hardwareMinimumLongSide,
                        // These render into ~93pt tiles, where deblocking is not visible but
                        // is a large fraction of the decode cost of a grid of animating GIFs.
                        // VideoToolbox ignores it.
                        skipLoopFilter: true,
                        selectedStream: .mediaType(.video),
                        seek: nil,
                        maxReadablePts: nil
                    ) ?? FFMpegFileReader(
                        // FFmpeg is built without an MPEG-4 Part 2 decoder, so such GIFs failed here and
                        // kept their placeholder. The target is a sample buffer display layer, which
                        // decodes compressed frames itself.
                        source: .file(self.dataPath),
                        passthroughDecoder: true,
                        useHardwareAcceleration: false,
                        selectedStream: .mediaType(.video),
                        seek: nil,
                        maxReadablePts: nil
                    )
                    if hardwareSlot {
                        if reader?.isHardwareAccelerated == true {
                            self.holdsHardwareSlot = true
                        } else {
                            BatchVideoRenderingContext.hardwareReaders.release()
                        }
                    }
                    if reader == nil {
                        self.isFailed = true
                        break outer
                    }
                    self.reader = reader
                    self.readerDidProduceFrame = false
                    self.readerWasRewound = false
                }
                
                guard let reader = self.reader else {
                    break outer
                }
                
                switch reader.readFrame() {
                case let .frame(frame):
                    self.readerDidProduceFrame = true
                    return createSampleBuffer(fromSampleBuffer: frame.sampleBuffer, withTimeOffset: .zero, duration: nil, displayImmediately: true)
                case .error:
                    self.isFailed = true
                    self.releaseReader()
                    break outer
                case .endOfStream:
                    if !self.readerDidProduceFrame {
                        if self.readerWasRewound {
                            // The rewind produced nothing: open the file again, as before.
                            self.releaseReader()
                            continue outer
                        }
                        // Nothing decodable in the whole file — fail permanently instead of
                        // looping. The target keeps its static thumbnail.
                        self.isFailed = true
                        break outer
                    }
                    // Loop the clip. Rewinding skips reopening and probing the file.
                    if reader.rewind() {
                        self.readerDidProduceFrame = false
                        self.readerWasRewound = true
                    } else {
                        self.releaseReader()
                    }
                case .waitingForMoreData:
                    // Invariant: the reader is only constructed once the consumer's
                    // `data.isComplete == true` (see `BatchVideoRenderingContext.update`),
                    // so a `.file(...)` source should never report waitingForMoreData.
                    // Treat it as fatal rather than spin if the invariant is ever violated.
                    self.isFailed = true
                    break outer
                }
            }
            return nil
        }
    }
    
    private final class TargetContext {
        weak var target: Target?
        let file: FileMediaReference
        let userLocation: MediaResourceUserLocation
        
        var readingContext: QueueLocalObject<ReadingContext>?
        var fetchDisposable: Disposable?
        var dataDisposable: Disposable?
        var dataPath: String?
        
        init(
            target: Target,
            file: FileMediaReference,
            userLocation: MediaResourceUserLocation
        ) {
            self.target = target
            self.file = file
            self.userLocation = userLocation
        }
        
        deinit {
            self.fetchDisposable?.dispose()
            self.dataDisposable?.dispose()
        }
    }
    
    private static let sharedQueue = Queue(name: "BatchVideoRenderingContext", qos: .default)
    // At most this many tiles decode with VideoToolbox at once (a grid shows ~18-24); the rest
    // decode in software. Session limits are not documented.
    fileprivate static let hardwareReaders = HardwareDecoderBudget(limit: 16)
    // Clips whose longer side is shorter decode in software, which costs less for them.
    fileprivate static let hardwareMinimumLongSide = 320
    
    private let context: AccountContext
    
    private var targetContexts: [Int: TargetContext] = [:]
    private var nextId: Int = 0
    
    private var isRendering: Bool = false
    private var displayLink: SharedDisplayLinkDriver.Link?
    
    public init(context: AccountContext) {
        self.context = context
    }
    
    public func add(target: Target, file: FileMediaReference, userLocation: MediaResourceUserLocation) -> TargetHandle {
        let id = self.nextId
        self.nextId += 1
        
        self.targetContexts[id] = TargetContext(
            target: target,
            file: file,
            userLocation: userLocation
        )
        self.update()
        
        return TargetHandle(context: self, id: id)
    }
    
    private func targetRemoved(id: Int) {
        if let removed = self.targetContexts.removeValue(forKey: id) {
            // Clear the leftover TargetState so a recycled target doesn't start its
            // next session by replaying our queued buffers and stale lastRenderedFrame.
            removed.target?.batchVideoRenderingTargetState = nil
            self.update()
        }
    }
    
    private func update() {
        var removeIds: [Int] = []
        for (id, targetContext) in self.targetContexts {
            if targetContext.target != nil {
                if targetContext.fetchDisposable == nil {
                    targetContext.fetchDisposable = self.context.engine.resources.fetch(
                        reference: targetContext.file.resourceReference(targetContext.file.media.resource),
                        userLocation: targetContext.userLocation,
                        userContentType: .sticker
                    ).startStrict()
                }
                if targetContext.dataDisposable == nil {
                    targetContext.dataDisposable = (self.context.engine.resources.data(resource: EngineMediaResource(targetContext.file.media.resource))
                    |> deliverOnMainQueue).startStrict(next: { [weak self, weak targetContext] data in
                        guard let self, let targetContext else {
                            return
                        }
                        if data.isComplete && targetContext.dataPath == nil {
                            targetContext.dataPath = data.path
                            self.update()
                        }
                    })
                }
                if targetContext.readingContext == nil, let dataPath = targetContext.dataPath {
                    targetContext.readingContext = QueueLocalObject(queue: BatchVideoRenderingContext.sharedQueue, generate: {
                        return ReadingContext(dataPath: dataPath)
                    })
                }
            } else {
                removeIds.append(id)
            }
        }
        for id in removeIds {
            self.targetContexts.removeValue(forKey: id)
        }
        
        self.updateDisplayLink()
    }

    private func updateDisplayLink() {
        if !self.targetContexts.isEmpty {
            if self.displayLink == nil {
                self.displayLink = SharedDisplayLinkDriver.shared.add { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.updateRendering()
                }
            }
        } else {
            self.displayLink = nil
        }
    }

    private func updateRendering() {
        if self.isRendering {
            return
        }
        
        var removeIds: [Int] = []
        var renderIds: [Int: Int] = [:]
        for (id, targetContext) in self.targetContexts {
            guard let target = targetContext.target else {
                removeIds.append(id)
                continue
            }
            let targetState: TargetState
            if let current = target.batchVideoRenderingTargetState {
                targetState = current
            } else {
                targetState = TargetState()
                target.batchVideoRenderingTargetState = targetState
            }
            
            if targetState.sampleBuffers.count < 2 {
                renderIds[id] = 2 - targetState.sampleBuffers.count
            }
        }
        
        for id in removeIds {
            self.targetContexts.removeValue(forKey: id)
        }
        
        if !renderIds.isEmpty {
            self.isRendering = true
            
            var readingContexts: [Int: (Int, QueueLocalObject<ReadingContext>)] = [:]
            for (id, count) in renderIds {
                guard let targetContext = self.targetContexts[id] else {
                    continue
                }
                if let readingContext = targetContext.readingContext {
                    readingContexts[id] = (count, readingContext)
                }
            }
            BatchVideoRenderingContext.sharedQueue.async { [weak self] in
                var sampleBuffers: [Int: [CMSampleBuffer]] = [:]
                for (id, (count, readingContext)) in readingContexts {
                    guard let readingContext = readingContext.unsafeGet() else {
                        sampleBuffers[id] = []
                        continue
                    }
                    sampleBuffers[id] = []
                    for _ in 0 ..< count {
                        if let sampleBuffer = readingContext.advance() {
                            sampleBuffers[id]?.append(sampleBuffer)
                        }
                    }
                }
                
                Queue.mainQueue().async {
                    guard let self else {
                        return
                    }
                    self.isRendering = false
                    
                    for (id, targetSampleBuffers) in sampleBuffers {
                        guard let targetContext = self.targetContexts[id], let target = targetContext.target, let targetState = target.batchVideoRenderingTargetState else {
                            continue
                        }
                        targetState.addSampleBuffers(sampleBuffers: targetSampleBuffers)
                    }
                    
                    self.updateFrames()
                }
            }
        } else {
            self.updateFrames()
        }
        
        self.updateDisplayLink()
    }
    
    private func updateFrames() {
        let timestamp = CACurrentMediaTime()
        for (_, targetContext) in self.targetContexts {
            guard let target = targetContext.target, let targetState = target.batchVideoRenderingTargetState else {
                continue
            }
            if let sampleBuffer = targetState.render(at: timestamp) {
                target.setSampleBuffer(sampleBuffer: sampleBuffer)
            }
        }
    }
}

private func createSampleBuffer(fromSampleBuffer sampleBuffer: CMSampleBuffer, withTimeOffset timeOffset: CMTime, duration: CMTime?, displayImmediately: Bool) -> CMSampleBuffer? {
    var itemCount: CMItemCount = 0
    var status = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &itemCount)
    if status != 0 {
        return nil
    }
    
    var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: CMTimeMake(value: 0, timescale: 0), presentationTimeStamp: CMTimeMake(value: 0, timescale: 0), decodeTimeStamp: CMTimeMake(value: 0, timescale: 0)), count: itemCount)
    status = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: itemCount, arrayToFill: &timingInfo, entriesNeededOut: &itemCount)
    if status != 0 {
        return nil
    }
    
    if let dur = duration {
        for i in 0 ..< itemCount {
            timingInfo[i].decodeTimeStamp = CMTimeAdd(timingInfo[i].decodeTimeStamp, timeOffset)
            timingInfo[i].presentationTimeStamp = CMTimeAdd(timingInfo[i].presentationTimeStamp, timeOffset)
            timingInfo[i].duration = dur
        }
    } else {
        for i in 0 ..< itemCount {
            timingInfo[i].decodeTimeStamp = CMTimeAdd(timingInfo[i].decodeTimeStamp, timeOffset)
            timingInfo[i].presentationTimeStamp = CMTimeAdd(timingInfo[i].presentationTimeStamp, timeOffset)
        }
    }
    
    var sampleBufferOffset: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: itemCount, sampleTimingArray: &timingInfo, sampleBufferOut: &sampleBufferOffset)
    guard let sampleBufferOffset else {
        return nil
    }
    
    if displayImmediately {
        let attachments: NSArray = CMSampleBufferGetSampleAttachmentsArray(sampleBufferOffset, createIfNecessary: true)! as NSArray
        let dict: NSMutableDictionary = attachments[0] as! NSMutableDictionary
        dict[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true as NSNumber
    }
    
    return sampleBufferOffset
}
