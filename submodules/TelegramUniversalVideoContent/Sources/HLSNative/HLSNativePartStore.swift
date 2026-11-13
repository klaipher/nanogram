import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import UniversalMediaPlayer
import HLSPlayback

// Turns on-disk segments into the player's parts. The bytes (the level's init, then the segment) are read from the
// media cache and probed in memory for their media times, then played in place from those ranges
// (`ChunkMediaPlayerPart.MediaBoxRanges`, which holds the resource against clean-up while the part lives): a cached
// segment is never written again. Only hardware AV1, which AVFoundation reads from a path, goes through a temp file
// (`HLSStreamingStorage.nativePartContent`, which accounts the write).
//
// The store owns those temp files and gives them back to `HLSTempFileCache`, which keeps the unused ones for a while so
// a segment made into a part again reuses its file. A removed part's file is disposed on the main-queue turn after the next parts list
// is built, by which time the player has that list: SwiftSignalKit delivers a main-queue signal synchronously on
// the main queue, so the player switches lists during the emission. (ChunkMediaPlayerPart.TempFile does not dispose
// its file; livestreams depend on that.) A part read from MediaBox has no file; releasing it releases the resource.
final class HLSNativePartStore {
    // A range MediaBox lost (a cleared cache) never completes a read; give up on it.
    private static let readTimeout: Double = 10.0
    
    private let engine: TelegramEngine
    private let mediaBox: MediaBox
    private let files: [HLSNativeQualityFile]
    private let queue = Queue(name: "HLSNativePartStore")
    
    private var parts: [HLSSegmentKey: ChunkMediaPlayerPart] = [:]
    private var pendingDisposal: [EngineTempBoxFile] = []
    private var makeDisposables: [HLSSegmentKey: Disposable] = [:]
    
    init(engine: TelegramEngine, mediaBox: MediaBox, files: [HLSNativeQualityFile]) {
        self.engine = engine
        self.mediaBox = mediaBox
        self.files = files
    }
    
    deinit {
        self.removeAll()
    }
    
    // Main queue in, main queue out.
    func makePart(level: Int, request: HLSAppendRequest, completion: @escaping (HLSAppendOutcome) -> Void) {
        guard level >= 0 && level < self.files.count else {
            completion(.failed)
            return
        }
        let qualityFile = self.files[level]
        let resource = EngineMediaResource(qualityFile.file.media.resource)
        let size = qualityFile.size
        let mediaBox = self.mediaBox
        let initRange = request.initRange
        let dataRange = request.dataRange
        let queue = self.queue
        
        let initData: Signal<Data?, NoError>
        if let initRange = request.initRange {
            initData = self.engine.resources.rangeData(resource: resource, size: size, range: initRange)
            |> take(1)
            |> map { data, isComplete -> Data? in
                return isComplete ? data : nil
            }
        } else {
            initData = .single(Data())
        }
        let segmentData = self.engine.resources.rangeData(resource: resource, size: size, range: request.dataRange)
        |> take(1)
        |> map { data, isComplete -> Data? in
            return isComplete ? data : nil
        }
        let bytes = combineLatest(initData, segmentData)
        |> take(1)
        |> map { initData, segmentData -> (Data, Data)? in
            guard let initData, let segmentData else {
                return nil
            }
            return (initData, segmentData)
        }
        |> timeout(HLSNativePartStore.readTimeout, queue: queue, alternate: .single(nil))
        
        // Probed on the store's queue; nothing is written unless the codec needs a file.
        let part: Signal<ChunkMediaPlayerPart?, NoError> = Signal { subscriber in
            let isCancelled = Atomic<Bool>(value: false)
            let disposable = (bytes |> deliverOn(queue)).start(next: { value in
                guard let (initData, segmentData) = value else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                // The parsers want the init and the segment as one buffer; this copy stays in memory.
                var combined = Data()
                combined.reserveCapacity(initData.count + segmentData.count)
                combined.append(initData)
                combined.append(segmentData)
                guard let trackTiming = HLSNativePartStore.trackTiming(data: combined), let timing = HLSPartTiming.range(audio: trackTiming.audio, video: trackTiming.video) else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                if isCancelled.with({ $0 }) {
                    return
                }
                guard let content = HLSStreamingStorage.nativePartContent(mediaBox: mediaBox, resource: resource._asResource(), resourceSize: size, initRange: initRange, dataRange: dataRange, initData: initData, segmentData: segmentData, codecName: trackTiming.videoCodecName) else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                if isCancelled.with({ $0 }) {
                    if let file = content.file {
                        HLSStreamingStorage.releaseTempFile(file)
                    }
                    return
                }
                subscriber.putNext(ChunkMediaPlayerPart(
                    startTime: timing.start,
                    endTime: timing.end,
                    content: content,
                    codecName: trackTiming.videoCodecName,
                    offsetTime: 0.0
                ))
                subscriber.putCompletion()
            })
            return ActionDisposable {
                let _ = isCancelled.swap(true)
                disposable.dispose()
            }
        }
        
        let key = request.key
        self.makeDisposables.removeValue(forKey: key)?.dispose()
        self.makeDisposables[key] = (part |> deliverOnMainQueue).startStrict(next: { [weak self] part in
            guard let self else {
                if let part {
                    if let file = part.content.file { HLSStreamingStorage.releaseTempFile(file) }
                }
                return
            }
            self.makeDisposables.removeValue(forKey: key)?.dispose()
            if let part {
                if let previous = self.parts[key] {
                    if let file = previous.content.file { self.pendingDisposal.append(file) }
                }
                self.parts[key] = part
                completion(.appended(start: part.startTime, end: part.endTime))
            } else {
                completion(.failed)
            }
        })
    }
    
    // Each track's start and duration and the video codec, from the part's boxes (`HLSFragmentTiming`), else from
    // FFmpeg's probe of the bytes in memory, which costs 15–80 ms a part on a phone.
    private static func trackTiming(data: Data) -> (audio: (start: Double, duration: Double)?, video: (start: Double, duration: Double)?, videoCodecName: String?)? {
        if let info = HLSFragmentTiming.parse(data) {
            return (info.audio.map { ($0.start, $0.duration) }, info.video.map { ($0.start, $0.duration) }, info.videoCodecName)
        }
        guard let mediaInfo = extractFFMpegMediaInfo(data: data) else {
            return nil
        }
        return (mediaInfo.audio.map { ($0.startTime.seconds, $0.duration.seconds) }, mediaInfo.video.map { ($0.startTime.seconds, $0.duration.seconds) }, mediaInfo.video?.codecName)
    }

    // The player's parts for the buffered segments, sorted by start time (the player reads them in array order).
    // Parts the controller no longer holds (a result it ignored after a seek or a quality change) are released.
    func parts(for buffered: [HLSBufferedPart]) -> [ChunkMediaPlayerPart] {
        let bufferedKeys = Set(buffered.map(\.key))
        for key in Array(self.parts.keys) where !bufferedKeys.contains(key) && self.makeDisposables[key] == nil {
            if let part = self.parts.removeValue(forKey: key) {
                if let file = part.content.file { self.pendingDisposal.append(file) }
            }
        }
        let result = buffered.compactMap({ self.parts[$0.key] }).sorted(by: { $0.startTime < $1.startTime })
        self.scheduleDisposal()
        return result
    }
    
    func remove(keys: [HLSSegmentKey]) {
        for key in keys {
            self.makeDisposables.removeValue(forKey: key)?.dispose()
            if let part = self.parts.removeValue(forKey: key) {
                if let file = part.content.file { self.pendingDisposal.append(file) }
            }
        }
    }
    
    func removeAll() {
        for (_, disposable) in self.makeDisposables {
            disposable.dispose()
        }
        self.makeDisposables.removeAll()
        for (_, part) in self.parts {
            if let file = part.content.file { HLSStreamingStorage.releaseTempFile(file) }
        }
        self.parts.removeAll()
        for file in self.pendingDisposal {
            HLSStreamingStorage.releaseTempFile(file)
        }
        self.pendingDisposal.removeAll()
    }
    
    private func scheduleDisposal() {
        if self.pendingDisposal.isEmpty {
            return
        }
        let files = self.pendingDisposal
        self.pendingDisposal.removeAll()
        // A real dispatch: Queue.mainQueue().async would run at once on the main queue, before the emission.
        DispatchQueue.main.async {
            for file in files {
                HLSStreamingStorage.releaseTempFile(file)
            }
        }
    }
}
