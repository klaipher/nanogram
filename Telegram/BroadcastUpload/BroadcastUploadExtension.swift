import Foundation
import ReplayKit
import CoreVideo
import TelegramVoip
import SwiftSignalKit
import BuildConfig
import BroadcastUploadHelpers
import AudioToolbox
import TelegramCore
import CoreMedia
import AVFoundation

private func rootPathForBasePath(_ appGroupPath: String) -> String {
    return appGroupPath + "/telegram-data"
}

private protocol BroadcastUploadImpl: AnyObject {
    func initialize(rootPath: String)
    func processVideoSampleBuffer(sampleBuffer: CMSampleBuffer)
    func processAudioSampleBuffer(data: Data)
}

private final class InProcessBroadcastUploadImpl: BroadcastUploadImpl {
    private weak var extensionContext: RPBroadcastSampleHandler?
    private var screencastBufferClientContext: IpcGroupCallBufferBroadcastContext?
    private var statusDisposable: Disposable?
    
    init(extensionContext: RPBroadcastSampleHandler) {
        self.extensionContext = extensionContext
    }
    
    deinit {
        self.statusDisposable?.dispose()
    }
    
    func initialize(rootPath: String) {
        let screencastBufferClientContext = IpcGroupCallBufferBroadcastContext(basePath: rootPath + "/broadcast-coordination")
        self.screencastBufferClientContext = screencastBufferClientContext

        var wasRunning = false
        self.statusDisposable = (screencastBufferClientContext.status
        |> deliverOnMainQueue).start(next: { [weak self] status in
            guard let self else {
                return
            }
            switch status {
            case .active:
                wasRunning = true
            case let .finished(reason):
                if wasRunning {
                    self.finish(with: .screencastEnded)
                } else {
                    self.finish(with: reason)
                }
            }
        })
    }
    
    private func finish(with reason: IpcGroupCallBufferBroadcastContext.Status.FinishReason) {
        guard let extensionContext = self.extensionContext else {
            return
        }
        var errorString: String?
        switch reason {
            case .callEnded:
                errorString = "You're not in a voice chat"
            case .error:
                errorString = "Finished"
            case .screencastEnded:
                break
        }
        if let errorString = errorString {
            let error = NSError(domain: "BroadcastUploadExtension", code: 1, userInfo: [
                NSLocalizedDescriptionKey: errorString
            ])
            extensionContext.finishBroadcastWithError(error)
        } else {
            finishBroadcastGracefully(extensionContext)
        }
    }
    
    func processVideoSampleBuffer(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        var orientation = CGImagePropertyOrientation.up
        if #available(iOS 11.0, *) {
            if let orientationAttachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
                orientation = CGImagePropertyOrientation(rawValue: orientationAttachment.uint32Value) ?? .up
            }
        }
        if let data = serializePixelBuffer(buffer: pixelBuffer) {
            self.screencastBufferClientContext?.setCurrentFrame(data: data, orientation: orientation)
        }
    }
    
    func processAudioSampleBuffer(data: Data) {
        self.screencastBufferClientContext?.writeAudioData(data: data)
    }
}

private final class EmbeddedBroadcastUploadImpl: BroadcastUploadImpl {
    private weak var extensionContext: RPBroadcastSampleHandler?
    
    private var clientContext: IpcGroupCallEmbeddedBroadcastContext?
    private var statusDisposable: Disposable?
    
    private var callContextId: UInt32?
    private var callContextDidSetJoinResponse: Bool = false
    private var callContext: OngoingGroupCallContext?
    private let screencastCapturer: OngoingCallVideoCapturer
    
    private var joinPayloadDisposable: Disposable?
    
    private var sampleBuffers: [CMSampleBuffer] = []
    private var lastAcceptedTimestamp: Double?
    /// Output buffers are recycled (IOSurface-backed, so the encoder takes them without a copy); a new one per frame
    /// was ~4.5 MB allocated 30 times a second against the extension's 50 MB limit.
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolKey: (width: Int, height: Int, format: OSType)?
    
    init(extensionContext: RPBroadcastSampleHandler) {
        self.extensionContext = extensionContext
        
        self.screencastCapturer = OngoingCallVideoCapturer(isCustom: true)
    }
    
    deinit {
        self.joinPayloadDisposable?.dispose()
    }
    
    func initialize(rootPath: String) {
        let clientContext = IpcGroupCallEmbeddedBroadcastContext(basePath: rootPath + "/embedded-broadcast-coordination")
        self.clientContext = clientContext
        
        var wasRunning = false
        self.statusDisposable = (clientContext.status
        |> deliverOnMainQueue).start(next: { [weak self] status in
            guard let self else {
                return
            }
            switch status {
            case let .active(id, joinResponse):
                wasRunning = true
                
                if self.callContextId != id {
                    if let callContext = self.callContext {
                        self.callContext = nil
                        self.callContextId = nil
                        self.callContextDidSetJoinResponse = false
                        self.joinPayloadDisposable?.dispose()
                        self.joinPayloadDisposable = nil
                        callContext.stop(account: nil, reportCallId: nil, debugLog: Promise())
                    }
                }
                
                if let id {
                    if self.callContext == nil {
                        self.callContextId = id
                        let callContext = OngoingGroupCallContext(
                            audioSessionActive: .single(true),
                            video: self.screencastCapturer,
                            requestMediaChannelDescriptions: { _, _ in EmptyDisposable },
                            rejoinNeeded: { },
                            outgoingAudioBitrateKbit: nil,
                            videoContentType: .screencast,
                            enableNoiseSuppression: false,
                            disableAudioInput: true,
                            enableSystemMute: false,
                            useReferenceImpl: false,
                            prioritizeVP8: false,
                            logPath: "",
                            onMutedSpeechActivityDetected: { _ in },
                            isConference: false,
                            audioIsActiveByDefault: true,
                            isStream: false,
                            sharedAudioDevice: nil,
                            encryptionContext: nil
                        )
                        self.callContext = callContext
                        self.joinPayloadDisposable = (callContext.joinPayload
                        |> deliverOnMainQueue).start(next: { [weak self] joinPayload in
                            guard let self else {
                                return
                            }
                            if self.callContextId != id {
                                return
                            }
                            self.clientContext?.joinPayload = IpcGroupCallEmbeddedAppContext.JoinPayload(
                                id: id,
                                data: joinPayload.0,
                                ssrc: joinPayload.1
                            )
                        })
                    }
                    
                    if let callContext = self.callContext {
                        if let joinResponse, !self.callContextDidSetJoinResponse {
                            self.callContextDidSetJoinResponse = true
                            callContext.setConnectionMode(.rtc, keepBroadcastConnectedIfWasEnabled: false, isUnifiedBroadcast: false)
                            callContext.setJoinResponse(payload: joinResponse.data)
                        }
                    }
                }
            case let .finished(reason):
                if wasRunning {
                    self.finish(with: .screencastEnded)
                } else {
                    self.finish(with: reason)
                }
            }
        })
    }
    
    private func finish(with reason: IpcGroupCallEmbeddedBroadcastContext.Status.FinishReason) {
        guard let extensionContext = self.extensionContext else {
            return
        }
        var errorString: String?
        switch reason {
            case .callEnded:
                errorString = "You're not in a voice chat"
            case .error:
                errorString = "Finished"
            case .screencastEnded:
                break
        }
        if let errorString = errorString {
            let error = NSError(domain: "BroadcastUploadExtension", code: 1, userInfo: [
                NSLocalizedDescriptionKey: errorString
            ])
            extensionContext.finishBroadcastWithError(error)
        } else {
            finishBroadcastGracefully(extensionContext)
        }
    }
    
    func processVideoSampleBuffer(sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if let lastAcceptedTimestamp = self.lastAcceptedTimestamp {
            if lastAcceptedTimestamp + 1.0 / 30.0 > timestamp {
                return
            }
        }
        self.lastAcceptedTimestamp = timestamp
        
        guard let sourceImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let sourcePixelBuffer: CVPixelBuffer = sourceImageBuffer as CVPixelBuffer
        
        let width = CVPixelBufferGetWidth(sourcePixelBuffer)
        let height = CVPixelBufferGetHeight(sourcePixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(sourcePixelBuffer)
        
        guard let outputPixelBuffer = self.makeOutputPixelBuffer(width: width, height: height, format: pixelFormat) else {
            return
        }
        CVPixelBufferLockBaseAddress(sourcePixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(sourcePixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outputPixelBuffer, [])
        }
        
        func copyRows(source: UnsafeMutableRawPointer?, sourceBytesPerRow: Int, output: UnsafeMutableRawPointer?, outputBytesPerRow: Int, rows: Int) {
            guard let source, let output else {
                return
            }
            if sourceBytesPerRow == outputBytesPerRow {
                memcpy(output, source, rows * outputBytesPerRow)
            } else {
                let rowBytes = min(sourceBytesPerRow, outputBytesPerRow)
                for y in 0 ..< rows {
                    memcpy(output.advanced(by: y * outputBytesPerRow), source.advanced(by: y * sourceBytesPerRow), rowBytes)
                }
            }
        }
        
        // ReplayKit's frames are bi-planar YUV: each plane has its own base address, stride and height. The
        // buffer's base address on a planar buffer is not the luma plane.
        if CVPixelBufferIsPlanar(sourcePixelBuffer) {
            let planeCount = min(CVPixelBufferGetPlaneCount(sourcePixelBuffer), CVPixelBufferGetPlaneCount(outputPixelBuffer))
            for plane in 0 ..< planeCount {
                copyRows(
                    source: CVPixelBufferGetBaseAddressOfPlane(sourcePixelBuffer, plane),
                    sourceBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(sourcePixelBuffer, plane),
                    output: CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, plane),
                    outputBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, plane),
                    rows: min(CVPixelBufferGetHeightOfPlane(sourcePixelBuffer, plane), CVPixelBufferGetHeightOfPlane(outputPixelBuffer, plane))
                )
            }
        } else {
            copyRows(
                source: CVPixelBufferGetBaseAddress(sourcePixelBuffer),
                sourceBytesPerRow: CVPixelBufferGetBytesPerRow(sourcePixelBuffer),
                output: CVPixelBufferGetBaseAddress(outputPixelBuffer),
                outputBytesPerRow: CVPixelBufferGetBytesPerRow(outputPixelBuffer),
                rows: height
            )
        }
        
        var orientation = CGImagePropertyOrientation.up
        if #available(iOS 11.0, *) {
            if let orientationAttachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
                orientation = CGImagePropertyOrientation(rawValue: orientationAttachment.uint32Value) ?? .up
            }
        }
        
        // No wait here: nothing signalled the old semaphore, so every frame blocked for 1/30 s. The timestamp gate
        // above already keeps the rate at 30 fps.
        if let outputSampleBuffer = sampleBufferFromPixelBuffer(pixelBuffer: outputPixelBuffer) {
            self.screencastCapturer.injectSampleBuffer(outputSampleBuffer, rotation: orientation, completion: {
            })
        }
    }
    
    private func makeOutputPixelBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if let key = self.pixelBufferPoolKey, key.width == width, key.height == height, key.format == format {
        } else {
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, pixelBufferAttributes as CFDictionary, &pool)
            self.pixelBufferPool = pool
            self.pixelBufferPoolKey = (width, height, format)
        }
        guard let pool = self.pixelBufferPool else {
            return nil
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        return pixelBuffer
    }
    
    func processAudioSampleBuffer(data: Data) {
        self.callContext?.addExternalAudioData(data: data)
    }
}

@available(iOS 10.0, *)
@objc(BroadcastUploadSampleHandler) class BroadcastUploadSampleHandler: RPBroadcastSampleHandler {
    private var impl: BroadcastUploadImpl?
    private var audioConverter: CustomAudioConverter?

    public override func beginRequest(with context: NSExtensionContext) {
        super.beginRequest(with: context)
    }
    
    private func finishWithError() {
        let errorString = "Finished"
        let error = NSError(domain: "BroadcastUploadExtension", code: 1, userInfo: [
            NSLocalizedDescriptionKey: errorString
        ])
        self.finishBroadcastWithError(error)
    }

    override public func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        guard let appBundleIdentifier = Bundle.main.bundleIdentifier, let lastDotRange = appBundleIdentifier.range(of: ".", options: [.backwards]) else {
            self.finishWithError()
            return
        }

        let baseAppBundleId = String(appBundleIdentifier[..<lastDotRange.lowerBound])

        let appGroupName = "group.\(baseAppBundleId)"
        let maybeAppGroupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)

        guard let appGroupUrl = maybeAppGroupUrl else {
            self.finishWithError()
            return
        }

        let rootPath = rootPathForBasePath(appGroupUrl.path)
        
        EngineTempBox.initializeShared(basePath: rootPath, processType: "share", launchSpecificId: Int64.random(in: Int64.min ... Int64.max))

        let logsPath = rootPath + "/logs/broadcast-logs"
        let _ = try? FileManager.default.createDirectory(atPath: logsPath, withIntermediateDirectories: true, attributes: nil)

        let embeddedBroadcastImplementationTypePath = rootPath + "/broadcast-coordination-type-v2"
        
        var useIPCContext = false
        if let typeData = try? Data(contentsOf: URL(fileURLWithPath: embeddedBroadcastImplementationTypePath)), let type = String(data: typeData, encoding: .utf8) {
            useIPCContext = type == "ipc"
        }
        
        let impl: BroadcastUploadImpl
        if useIPCContext {
            impl = EmbeddedBroadcastUploadImpl(extensionContext: self)
        } else {
            impl = InProcessBroadcastUploadImpl(extensionContext: self)
        }
        self.impl = impl
        impl.initialize(rootPath: rootPath)
    }

    override public func broadcastPaused() {
    }

    override public func broadcastResumed() {
    }

    override public func broadcastFinished() {
    }

    override public func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case RPSampleBufferType.video:
            processVideoSampleBuffer(sampleBuffer: sampleBuffer)
        case RPSampleBufferType.audioApp:
            processAudioSampleBuffer(sampleBuffer: sampleBuffer)
        case RPSampleBufferType.audioMic:
            break
        @unknown default:
            break
        }
    }

    private func processVideoSampleBuffer(sampleBuffer: CMSampleBuffer) {
        self.impl?.processVideoSampleBuffer(sampleBuffer: sampleBuffer)
    }

    private func processAudioSampleBuffer(sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        let format = CustomAudioConverter.Format(asbd.pointee)
        if self.audioConverter?.format != format {
            self.audioConverter = CustomAudioConverter(asbd: asbd)
        }
        if let audioConverter = self.audioConverter {
            if let data = audioConverter.convert(sampleBuffer: sampleBuffer), !data.isEmpty {
                self.impl?.processAudioSampleBuffer(data: data)
            }
        }
    }
}

/// Returned by the input callback when the current buffer is used up. Unlike 0 packets with `noErr` (end of
/// stream), it keeps the converter's resampler state for the next buffer, so consecutive buffers join without
/// clicks.
private let converterInputExhausted: OSStatus = 0x6E6F6D6F // 'nomo'

/// One converter per input format, kept across buffers (a new AudioConverter every ~20 ms cost CPU and restarted
/// the resampler each time).
private final class CustomAudioConverter {
    struct Format: Equatable {
        let sampleRate: Double
        let formatId: AudioFormatID
        let formatFlags: AudioFormatFlags
        let bytesPerPacket: UInt32
        let channelsPerFrame: UInt32
        let bitsPerChannel: UInt32

        init(_ asbd: AudioStreamBasicDescription) {
            self.sampleRate = asbd.mSampleRate
            self.formatId = asbd.mFormatID
            self.formatFlags = asbd.mFormatFlags
            self.bytesPerPacket = asbd.mBytesPerPacket
            self.channelsPerFrame = asbd.mChannelsPerFrame
            self.bitsPerChannel = asbd.mBitsPerChannel
        }
    }

    let format: Format
    private var inputDescription: AudioStreamBasicDescription
    private var outputDescription = AudioStreamBasicDescription(
        mSampleRate: 48000.0,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    private var audioConverter: AudioConverterRef?
    private let outputSize = 32768 * 2
    private var outputBuffer: UnsafeMutableRawPointer

    var currentBuffer: AudioBuffer?
    var currentBufferOffset: UInt32 = 0
    var currentBytesPerPacket: UInt32 {
        return self.inputDescription.mBytesPerPacket
    }

    init(asbd: UnsafePointer<AudioStreamBasicDescription>) {
        self.format = Format(asbd.pointee)
        self.inputDescription = asbd.pointee
        self.outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: self.outputSize, alignment: 16)
        var audioConverter: AudioConverterRef?
        if AudioConverterNew(&self.inputDescription, &self.outputDescription, &audioConverter) == noErr {
            self.audioConverter = audioConverter
        }
    }

    deinit {
        if let audioConverter = self.audioConverter {
            AudioConverterDispose(audioConverter)
        }
        self.outputBuffer.deallocate()
    }

    func convert(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        var bufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer? = nil
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        let size = bufferList.mBuffers.mDataByteSize
        guard size != 0, let mData = bufferList.mBuffers.mData else {
            return nil
        }

        guard let audioConverter = self.audioConverter, self.inputDescription.mBytesPerPacket != 0 else {
            return nil
        }

        self.currentBuffer = AudioBuffer(
            mNumberChannels: asbd.pointee.mChannelsPerFrame,
            mDataByteSize: UInt32(size),
            mData: mData
        )
        self.currentBufferOffset = 0

        var outputBufferList = AudioBufferList()
        outputBufferList.mNumberBuffers = 1
        outputBufferList.mBuffers.mNumberChannels = self.outputDescription.mChannelsPerFrame
        outputBufferList.mBuffers.mDataByteSize = UInt32(self.outputSize)
        outputBufferList.mBuffers.mData = self.outputBuffer

        var outputDataPacketSize = UInt32(self.outputSize) / self.outputDescription.mBytesPerPacket

        let result = AudioConverterFillComplexBuffer(
            audioConverter,
            converterComplexInputDataProc,
            Unmanaged.passUnretained(self).toOpaque(),
            &outputDataPacketSize,
            &outputBufferList,
            nil
        )
        self.currentBuffer = nil
        withExtendedLifetime(blockBuffer) {
        }
        guard result == noErr || result == converterInputExhausted else {
            return nil
        }
        return Data(bytes: self.outputBuffer, count: Int(outputDataPacketSize * self.outputDescription.mBytesPerPacket))
    }
}

private func converterComplexInputDataProc(inAudioConverter: AudioConverterRef, ioNumberDataPackets: UnsafeMutablePointer<UInt32>, ioData: UnsafeMutablePointer<AudioBufferList>, ioDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?, inUserData: UnsafeMutableRawPointer?) -> Int32 {
    guard let inUserData = inUserData else {
        ioNumberDataPackets.pointee = 0
        return 0
    }
    let instance = Unmanaged<CustomAudioConverter>.fromOpaque(inUserData).takeUnretainedValue()
    let bytesPerPacket = instance.currentBytesPerPacket
    guard let currentBuffer = instance.currentBuffer, bytesPerPacket != 0 else {
        ioNumberDataPackets.pointee = 0
        return converterInputExhausted
    }

    let numPacketsInBuffer = currentBuffer.mDataByteSize / bytesPerPacket
    let numPacketsAvailable = numPacketsInBuffer - instance.currentBufferOffset / bytesPerPacket
    if numPacketsAvailable == 0 {
        ioNumberDataPackets.pointee = 0
        return converterInputExhausted
    }

    let numPacketsToRead = min(ioNumberDataPackets.pointee, numPacketsAvailable)
    ioNumberDataPackets.pointee = numPacketsToRead

    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = currentBuffer.mData?.advanced(by: Int(instance.currentBufferOffset))
    ioData.pointee.mBuffers.mDataByteSize = numPacketsToRead * bytesPerPacket
    ioData.pointee.mBuffers.mNumberChannels = currentBuffer.mNumberChannels

    instance.currentBufferOffset += numPacketsToRead * bytesPerPacket

    return 0
}

private func sampleBufferFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    var maybeFormat: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &maybeFormat)
    if status != noErr {
        return nil
    }
    guard let format = maybeFormat else {
        return nil
    }

    var timingInfo = CMSampleTimingInfo(
        duration: CMTimeMake(value: 1, timescale: 30),
        presentationTimeStamp: CMTimeMake(value: 0, timescale: 30),
        decodeTimeStamp: CMTimeMake(value: 0, timescale: 30)
    )

    var maybeSampleBuffer: CMSampleBuffer?
    let bufferStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timingInfo, sampleBufferOut: &maybeSampleBuffer)

    if (bufferStatus != noErr) {
        return nil
    }
    guard let sampleBuffer = maybeSampleBuffer else {
        return nil
    }

    let attachments: NSArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)! as NSArray
    let dict: NSMutableDictionary = attachments[0] as! NSMutableDictionary
    dict[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true as NSNumber

    return sampleBuffer
}
