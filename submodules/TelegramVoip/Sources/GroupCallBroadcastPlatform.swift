#if os(macOS)
import Foundation
import QuartzCore
import SwiftSignalKit
import TgVoipWebrtc
import BroadcastPlayback

public final class GroupCallBroadcastPlatform: BroadcastListenerPlatform {
    private final class Token: BroadcastCancellable {
        var cancelled = false
        var disposable: Disposable?

        func cancel() {
            self.cancelled = true
            self.disposable?.dispose()
            self.disposable = nil
        }
    }

    private let queue: Queue
    private let audioCore: OpaquePointer
    private let fetcher: () -> GroupCallBroadcastFetcher?
    private let videoOutput: GroupCallBroadcastVideoOutput
    private let rejoinNeeded: () -> Void
    private let decodeQueue: DispatchQueue
    private let enqueue: (BroadcastListenerAudioPartRef, Int64) -> Bool
    private var isClosed = false

    public init(queue: Queue, audioCore: OpaquePointer, fetcher: @escaping () -> GroupCallBroadcastFetcher?, videoOutput: GroupCallBroadcastVideoOutput, rejoinNeeded: @escaping () -> Void, decodeQueue: DispatchQueue = DispatchQueue(label: "GroupCallBroadcast.audio-decode"), enqueue: ((BroadcastListenerAudioPartRef, Int64) -> Bool)? = nil) {
        self.queue = queue
        self.audioCore = audioCore
        self.fetcher = fetcher
        self.videoOutput = videoOutput
        self.rejoinNeeded = rejoinNeeded
        self.decodeQueue = decodeQueue
        if let enqueue {
            self.enqueue = enqueue
        } else {
            self.enqueue = { part, timestampMs in
                return BroadcastListenerAudioPartEnqueue(part, audioCore, timestampMs)
            }
        }
    }

    public func close() {
        self.isClosed = true
    }

    public var now: Double {
        return BroadcastAudioCoreNow(self.audioCore)
    }

    public func schedule(after delay: Double, _ action: @escaping () -> Void) -> BroadcastCancellable {
        let token = Token()
        self.queue.after(max(0.0, delay), { [weak self] in
            guard let self, !self.isClosed, !token.cancelled else {
                return
            }
            action()
        })
        return token
    }

    private func onQueue(_ token: Token, _ f: @escaping () -> Void) {
        let deliver: () -> Void = { [weak self] in
            guard let self, !self.isClosed, !token.cancelled else {
                return
            }
            f()
        }
        if self.queue.isCurrent() {
            deliver()
        } else {
            self.queue.async(deliver)
        }
    }

    public func requestLiveEdge(completion: @escaping (BroadcastEdgeOutcome) -> Void) -> BroadcastCancellable {
        let token = Token()
        guard let fetcher = self.fetcher() else {
            completion(.failed)
            return token
        }
        token.disposable = fetcher.edge(completion: { [weak self] outcome in
            self?.onQueue(token, {
                completion(outcome)
            })
        })
        return token
    }

    public func loadPart(_ request: BroadcastPartRequest, completion: @escaping (BroadcastPartOutcome, Data?) -> Void) -> BroadcastCancellable {
        let token = Token()
        guard let fetcher = self.fetcher() else {
            completion(.notReady, nil)
            return token
        }
        token.disposable = fetcher.load(request, completion: { [weak self] outcome, data in
            self?.onQueue(token, {
                completion(outcome, data)
            })
        })
        return token
    }

    public func handOverAudio(segmentTimestampMs: Int64, data: Data, gate: BroadcastAudioHandover.Gate) {
        let queue = self.queue
        let enqueue = self.enqueue
        self.decodeQueue.async { [weak self] in
            let part = data.withUnsafeBytes { raw -> BroadcastListenerAudioPartRef? in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return nil
                }
                return BroadcastListenerAudioDecode(base, raw.count)
            }
            guard let part else {
                return
            }
            queue.async {
                if let self, !self.isClosed, !gate.isClosed {
                    let _ = enqueue(part, segmentTimestampMs)
                }
                BroadcastListenerAudioPartRelease(part)
            }
        }
    }

    public func playAudio(segmentTimestampMs: Int64, at hostTime: Double, offsetMs: Int) {
        if self.isClosed {
            return
        }
        let _ = BroadcastAudioCorePlay(self.audioCore, segmentTimestampMs, hostTime, Int32(offsetMs))
    }

    public func setAudioActive(_ isActive: Bool) {
        if self.isClosed {
            return
        }
        BroadcastAudioCoreSetActive(self.audioCore, isActive)
    }

    public func setAudioVolume(ssrc: UInt32, volume: Float) {
        if self.isClosed {
            return
        }
        BroadcastAudioCoreSetVolume(self.audioCore, ssrc, volume)
    }

    public func resetAudio() {
        if self.isClosed {
            return
        }
        BroadcastAudioCoreReset(self.audioCore)
    }

    public func takeAudioLevels() -> [BroadcastAudioLevelSample] {
        if self.isClosed {
            return []
        }
        var levels = [BroadcastAudioLevel](repeating: BroadcastAudioLevel(), count: 64)
        let count = BroadcastAudioCoreTakeLevels(self.audioCore, &levels, levels.count)
        return levels.prefix(count).map { BroadcastAudioLevelSample(ssrc: $0.ssrc, level: $0.level, voice: $0.voice) }
    }

    public func deliverVideo(_ segment: BroadcastSegment, data: [BroadcastPartRequest: Data]) {
        if self.isClosed {
            return
        }
        self.videoOutput.deliver(segment, data: data)
    }

    public func playVideo(segmentTimestampMs: Int64, at hostTime: Double, offsetMs: Int) {
        if self.isClosed {
            return
        }
        self.videoOutput.play(segmentTimestampMs: segmentTimestampMs, hostTime: hostTime, offsetMs: offsetMs)
    }

    public func stopVideo() {
        self.videoOutput.stop()
    }

    public func requestRejoin() {
        if self.isClosed {
            return
        }
        self.rejoinNeeded()
    }
}
#endif
