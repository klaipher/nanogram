import Foundation
import AVFoundation
import CoreMedia
import FFMpegBinding
import VideoToolbox
import MediaCapabilities

#if os(macOS)
public let internal_isHardwareAv1Supported: Bool = MediaCapabilities.isHardwareAv1Supported
#endif

public enum MediaDataReaderReadSampleBufferResult {
    case frame(CMSampleBuffer)
    case waitingForMoreData
    case endOfStream
    case error
}

public protocol MediaDataReader: AnyObject {
    var hasVideo: Bool { get }
    var hasAudio: Bool { get }
    var videoRotationAngle: Double { get }
        
    func readSampleBuffer() -> MediaDataReaderReadSampleBufferResult
}

public final class FFMpegMediaDataReaderV2: MediaDataReader {
    public enum Content {
        case tempFile(ChunkMediaPlayerPart.TempFile)
        case mediaBoxRanges(ChunkMediaPlayerPart.MediaBoxRanges)
        case directStream(ChunkMediaPlayerPartsState.DirectReader.Stream)
    }
    
    private let content: Content
    private let isVideo: Bool
    private let videoSource: FFMpegFileReader?
    private let audioSource: FFMpegFileReader?
    
    public var videoRotationAngle: Double {
        return self.videoSource?.videoRotationAngle ?? 0.0
    }

    public var hasVideo: Bool {
        return self.videoSource != nil
    }
    
    public var hasAudio: Bool {
        return self.audioSource != nil
    }
    
    public convenience init(content: Content, isVideo: Bool, codecName: String?) {
        self.init(content: content, isVideo: isVideo, codecName: codecName, ignoreEditList: false)
    }

    // `startAt` (a file's own time): the reader starts at the keyframe before it and decodes no non-reference frame
    // before it, since frames before it are only decoded to be hidden.
    public init(content: Content, isVideo: Bool, codecName: String?, ignoreEditList: Bool, startAt: Double? = nil) {
        self.content = content
        self.isVideo = isVideo
        
        let source: FFMpegFileReader.SourceDescription
        var seek: FFMpegFileReader.Seek?
        var maxReadablePts: (streamIndex: Int, pts: Int64, isEnded: Bool)?
        var skipNonReferenceFramesBefore: Double?
        // An HLS part's two readers each describe only their own stream.
        var probeOnlySelectedMediaType = false
        switch content {
        case let .tempFile(tempFile):
            source = .file(tempFile.file.path)
            probeOnlySelectedMediaType = true
            if let startAt {
                seek = .direct(position: startAt)
                skipNonReferenceFramesBefore = startAt
            }
        case let .mediaBoxRanges(ranges):
            source = .resource(mediaBox: ranges.mediaBox, resource: ranges.resource, resourceSize: ranges.resourceSize, mappedRanges: ranges.ranges)
            // The same start as a temp file part: a zero-copy part is read by the same HLS reader.
            probeOnlySelectedMediaType = true
            if let startAt {
                seek = .direct(position: startAt)
                skipNonReferenceFramesBefore = startAt
            }
        case let .directStream(directStream):
            let mappedRanges: [Range<Int64>]
            #if DEBUG && false
            var mappedRangesValue: [Range<Int64>] = []
            var testOffset: Int64 = 0
            while testOffset < directStream.size {
                let testBlock: Int64 = min(3 * 1024 + 1, directStream.size - testOffset)
                mappedRangesValue.append(testOffset ..< (testOffset + testBlock))
                testOffset += testBlock
            }
            mappedRanges = mappedRangesValue
            #else
            mappedRanges = [0 ..< directStream.size]
            #endif
            source = .resource(mediaBox: directStream.mediaBox, resource: directStream.resource, resourceSize: directStream.size, mappedRanges: mappedRanges)
            seek = .stream(streamIndex: directStream.seek.streamIndex, pts: directStream.seek.pts)
            maxReadablePts = directStream.maxReadablePts
        }
        
        if self.isVideo {
            var passthroughDecoder = true
            var useHardwareAcceleration = false
            
            if (codecName == "h264" || codecName == "hevc") {
                passthroughDecoder = false
                #if targetEnvironment(simulator)
                useHardwareAcceleration = false
                #else
                useHardwareAcceleration = true
                #endif
            }
            if (codecName == "av1" || codecName == "av01") {
                passthroughDecoder = false
                useHardwareAcceleration = internal_isHardwareAv1Supported
            }
            if codecName == "vp9" || codecName == "vp8" {
                passthroughDecoder = false
            }
            
            /*#if DEBUG
            if codecName == "h264" {
                passthroughDecoder = false
                useHardwareAcceleration = true
            }
            #endif*/
            
            if let videoSource = FFMpegFileReader(source: source, passthroughDecoder: passthroughDecoder, useHardwareAcceleration: useHardwareAcceleration, selectedStream: .mediaType(.video), seek: seek, maxReadablePts: maxReadablePts, ignoreEditList: ignoreEditList, skipNonReferenceFramesBefore: skipNonReferenceFramesBefore, probeOnlySelectedMediaType: probeOnlySelectedMediaType) {
                self.videoSource = videoSource
            } else {
                self.videoSource = nil
            }
            self.audioSource = nil
        } else {
            if let audioSource = FFMpegFileReader(source: source, passthroughDecoder: false, useHardwareAcceleration: false, selectedStream: .mediaType(.audio), seek: seek, maxReadablePts: maxReadablePts, ignoreEditList: ignoreEditList, probeOnlySelectedMediaType: probeOnlySelectedMediaType) {
                self.audioSource = audioSource
            } else {
                self.audioSource = nil
            }
            self.videoSource = nil
        }
    }
    
    public func update(content: Content) {
        guard case let .directStream(directStream) = content else {
            return
        }
        if let audioSource = self.audioSource {
            audioSource.updateMaxReadablePts(pts: directStream.maxReadablePts)
        } else if let videoSource = self.videoSource {
            videoSource.updateMaxReadablePts(pts: directStream.maxReadablePts)
        }
    }
    
    public func readSampleBuffer() -> MediaDataReaderReadSampleBufferResult {
        if let videoSource {
            switch videoSource.readFrame() {
            case let .frame(frame):
                return .frame(frame.sampleBuffer)
            case .waitingForMoreData:
                return .waitingForMoreData
            case .endOfStream:
                return .endOfStream
            case .error:
                return .error
            }
        } else if let audioSource {
            switch audioSource.readFrame() {
            case let .frame(frame):
                return .frame(frame.sampleBuffer)
            case .waitingForMoreData:
                return .waitingForMoreData
            case .endOfStream:
                return .endOfStream
            case .error:
                return .error
            }
        } else {
            return .endOfStream
        }
    }
}

public final class FFMpegMediaDataReaderV1: MediaDataReader {
    private let isVideo: Bool
    private let videoSource: SoftwareVideoReader?
    private let audioSource: SoftwareAudioSource?
    
    public var videoRotationAngle: Double {
        return self.videoSource?.videoRotationAngle ?? 0.0
    }

    public var hasVideo: Bool {
        return self.videoSource != nil
    }
    
    public var hasAudio: Bool {
        return self.audioSource != nil
    }
    
    public convenience init(filePath: String, isVideo: Bool, codecName: String?) {
        self.init(filePath: filePath, isVideo: isVideo, codecName: codecName, ignoreEditList: false)
    }

    public init(filePath: String, isVideo: Bool, codecName: String?, ignoreEditList: Bool) {
        self.isVideo = isVideo
        
        if self.isVideo {
            var passthroughDecoder = true
            if (codecName == "av1" || codecName == "av01") && !internal_isHardwareAv1Supported {
                passthroughDecoder = false
            }
            let videoSource = SoftwareVideoReader(path: filePath, hintVP9: false, passthroughDecoder: passthroughDecoder)
            if videoSource.hasStream {
                self.videoSource = videoSource
            } else {
                self.videoSource = nil
            }
            self.audioSource = nil
        } else {
            let audioSource = SoftwareAudioSource(path: filePath, ignoreEditList: ignoreEditList, isPlayback: true)
            if audioSource.hasStream {
                self.audioSource = audioSource
            } else {
                self.audioSource = nil
            }
            self.videoSource = nil
        }
    }
    
    public func readSampleBuffer() -> MediaDataReaderReadSampleBufferResult {
        if let videoSource {
            let frame = videoSource.readFrame()
            if let frame {
                return .frame(frame.sampleBuffer)
            } else {
                return .endOfStream
            }
        } else if let audioSource {
            if let sampleBuffer = audioSource.readSampleBuffer() {
                return .frame(sampleBuffer)
            } else {
                return .endOfStream
            }
        } else {
            return .endOfStream
        }
    }
}

private final class LoadedVideoTrackResult: @unchecked Sendable {
    var value: LoadedVideoTrack?
}

private final class LoadedVideoTrack: @unchecked Sendable {
    let track: AVAssetTrack
    let preferredTransform: CGAffineTransform
    let formatDescriptions: [CMFormatDescription]

    private init(track: AVAssetTrack, preferredTransform: CGAffineTransform, formatDescriptions: [CMFormatDescription]) {
        self.track = track
        self.preferredTransform = preferredTransform
        self.formatDescriptions = formatDescriptions
    }

    static func load(from asset: AVAsset) -> LoadedVideoTrack? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LoadedVideoTrackResult()
        Task.detached {
            defer {
                semaphore.signal()
            }
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let preferredTransform = try? await track.load(.preferredTransform),
                  let formatDescriptions = try? await track.load(.formatDescriptions) else {
                return
            }
            result.value = LoadedVideoTrack(track: track, preferredTransform: preferredTransform, formatDescriptions: formatDescriptions)
        }
        semaphore.wait()
        return result.value
    }
}

public final class AVAssetVideoDataReader: MediaDataReader {
    public private(set) var videoRotationAngle: Double = 0.0

    private let isVideo: Bool
    private var mediaInfo: FFMpegMediaInfo.Info?
    private var assetReader: AVAssetReader?
    private var assetOutput: AVAssetReaderOutput?
    
    public var hasVideo: Bool {
        return self.assetOutput != nil
    }
    
    public var hasAudio: Bool {
        return false
    }
    
    public init(filePath: String, isVideo: Bool) {
        self.isVideo = isVideo
        
        if self.isVideo {
            guard let video = extractFFMpegMediaInfo(path: filePath)?.video else {
                return
            }
            self.mediaInfo = video
            
            let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
            guard let assetReader = try? AVAssetReader(asset: asset) else {
                return
            }
            guard let loadedTrack = LoadedVideoTrack.load(from: asset) else {
                return
            }
            let videoTrack = loadedTrack.track
            let transform = loadedTrack.preferredTransform
            self.videoRotationAngle = atan2(Double(transform.b), Double(transform.a))
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [String(kCVPixelBufferPixelFormatTypeKey): AVAssetVideoDataReader.outputPixelFormat(formatDescription: loadedTrack.formatDescriptions.first)])
            assetReader.add(videoOutput)
            if assetReader.startReading() {
                self.assetReader = assetReader
                self.assetOutput = videoOutput
            }
        }
    }
    
    static func outputPixelFormat(formatDescription: CMFormatDescription?) -> OSType {
        guard let formatDescription else {
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        if let bitsPerComponent = CMFormatDescriptionGetExtension(formatDescription, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber, bitsPerComponent.intValue > 8 {
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        if let transferFunction = CMFormatDescriptionGetExtension(formatDescription, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
            if transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) || transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            }
        }
        return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
    
    public func readSampleBuffer() -> MediaDataReaderReadSampleBufferResult {
        guard let mediaInfo = self.mediaInfo, let assetReader = self.assetReader, let assetOutput = self.assetOutput else {
            return .endOfStream
        }
        var retryCount = 0
        while true {
            if let sampleBuffer = assetOutput.copyNextSampleBuffer() {
                if let convertedSampleBuffer = createSampleBuffer(fromSampleBuffer: sampleBuffer, withTimeOffset: mediaInfo.startTime, duration: nil) {
                    return .frame(convertedSampleBuffer)
                } else {
                    return .endOfStream
                }
            } else if assetReader.status == .reading && retryCount < 100 {
                Thread.sleep(forTimeInterval: 1.0 / 60.0)
                retryCount += 1
            } else {
                break
            }
        }
        
        return .endOfStream
    }
}

private func createSampleBuffer(fromSampleBuffer sampleBuffer: CMSampleBuffer, withTimeOffset timeOffset: CMTime, duration: CMTime?) -> CMSampleBuffer? {
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
    
    if let output = sampleBufferOffset {
        return output
    } else {
        return nil
    }
}
