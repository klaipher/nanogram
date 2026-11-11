#if os(macOS)
import Foundation
import QuartzCore
import SwiftSignalKit
import TgVoipWebrtc
import BroadcastPlayback

public final class GroupCallBroadcastVideoOutput {
    private final class Endpoint {
        let id: String
        let queue: DispatchQueue
        let decoder: BroadcastVideoDecoderRef
        let frames: ValuePipe<OngoingGroupCallContext.VideoFrameData>
        var parts: [Int64: BroadcastVideoPartRef] = [:]
        var playhead: BroadcastPlayhead
        var shown: (timestampMs: Int64, index: Int32)?
        var timer: DispatchSourceTimer?
        var lastDeliveredMs: Int64 = Int64.min

        init(id: String, playhead: BroadcastPlayhead, frames: ValuePipe<OngoingGroupCallContext.VideoFrameData>) {
            self.id = id
            self.playhead = playhead
            self.frames = frames
            self.queue = DispatchQueue(label: "GroupCallBroadcastVideo.\(id)")
            self.decoder = BroadcastVideoDecoderCreate(true)
        }
    }

    private var endpoints: [String: Endpoint] = [:]
    private var playhead = BroadcastPlayhead()
    private let pipes = Atomic<[String: ValuePipe<OngoingGroupCallContext.VideoFrameData>]>(value: [:])

    public init() {
    }

    var endpointIds: [String] {
        return self.endpoints.keys.sorted()
    }

    public func video(endpointId: String) -> Signal<OngoingGroupCallContext.VideoFrameData, NoError> {
        return self.pipe(endpointId).signal()
    }

    public func deliver(_ segment: BroadcastSegment, data: [BroadcastPartRequest: Data]) {
        for (endpointId, request) in segment.video {
            guard let bytes = data[request] else {
                continue
            }
            let endpoint = self.endpoint(endpointId)
            let timestampMs = segment.timestampMs
            endpoint.lastDeliveredMs = max(endpoint.lastDeliveredMs, timestampMs)
            endpoint.queue.async {
                let part = bytes.withUnsafeBytes { raw -> BroadcastVideoPartRef? in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                        return nil
                    }
                    return BroadcastVideoPartOpen(endpoint.decoder, base, raw.count)
                }
                if let previous = endpoint.parts[timestampMs] {
                    BroadcastVideoPartRelease(previous)
                }
                endpoint.parts[timestampMs] = part
            }
        }
    }

    public func play(segmentTimestampMs: Int64, hostTime: Double, offsetMs: Int) {
        let play = BroadcastPlayhead.Play(timestampMs: segmentTimestampMs, hostTime: hostTime, offsetMs: offsetMs)
        self.playhead.add(play)
        let playing = self.playhead.active(at: CACurrentMediaTime())
        for endpoint in self.endpoints.values {
            if let playing, endpoint.lastDeliveredMs < playing.timestampMs {
                self.retire(endpoint)
                continue
            }
            endpoint.queue.async {
                endpoint.playhead.add(play)
            }
        }
    }

    private func retire(_ endpoint: Endpoint) {
        self.endpoints.removeValue(forKey: endpoint.id)
        endpoint.queue.async {
            endpoint.timer?.cancel()
            endpoint.timer = nil
            for part in endpoint.parts.values {
                BroadcastVideoPartRelease(part)
            }
            endpoint.parts.removeAll()
            BroadcastVideoDecoderRelease(endpoint.decoder)
        }
    }

    public func stop() {
        for endpoint in self.endpoints.values {
            endpoint.queue.sync {
                endpoint.timer?.cancel()
                endpoint.timer = nil
                for part in endpoint.parts.values {
                    BroadcastVideoPartRelease(part)
                }
                endpoint.parts.removeAll()
                endpoint.playhead = BroadcastPlayhead()
            }
            BroadcastVideoDecoderRelease(endpoint.decoder)
        }
        self.endpoints.removeAll()
        self.playhead = BroadcastPlayhead()
    }

    private func pipe(_ endpointId: String) -> ValuePipe<OngoingGroupCallContext.VideoFrameData> {
        let pipes = self.pipes.modify { pipes in
            var pipes = pipes
            if pipes[endpointId] == nil {
                pipes[endpointId] = ValuePipe()
            }
            return pipes
        }
        if let pipe = pipes[endpointId] {
            return pipe
        }
        return ValuePipe()
    }

    private func endpoint(_ id: String) -> Endpoint {
        if let endpoint = self.endpoints[id] {
            return endpoint
        }
        let endpoint = Endpoint(id: id, playhead: self.playhead, frames: self.pipe(id))
        self.endpoints[id] = endpoint
        let timer = DispatchSource.makeTimerSource(queue: endpoint.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
        timer.setEventHandler { [weak endpoint] in
            guard let endpoint else {
                return
            }
            GroupCallBroadcastVideoOutput.show(endpoint)
        }
        endpoint.timer = timer
        timer.resume()
        return endpoint
    }

    private static func show(_ endpoint: Endpoint) {
        let now = CACurrentMediaTime()
        guard let playing = endpoint.playhead.active(at: now) else {
            return
        }
        for (timestampMs, part) in endpoint.parts where timestampMs < playing.timestampMs {
            BroadcastVideoPartRelease(part)
            endpoint.parts.removeValue(forKey: timestampMs)
        }
        guard let part = endpoint.parts[playing.timestampMs] else {
            return
        }
        var frame = BroadcastVideoFrame()
        guard BroadcastVideoPartFrameAt(part, playing.secondsIntoSegment(at: now), &frame) else {
            return
        }
        if let shown = endpoint.shown, shown.timestampMs == playing.timestampMs, shown.index == frame.index {
            return
        }
        endpoint.shown = (playing.timestampMs, frame.index)
        if let frameData = GroupCallBroadcastVideoOutput.frameData(frame) {
            endpoint.frames.putNext(frameData)
        }
    }

    private static func frameData(_ frame: BroadcastVideoFrame) -> OngoingGroupCallContext.VideoFrameData? {
        if let pixelBuffer = frame.pixelBuffer?.takeUnretainedValue() {
            return OngoingGroupCallContext.VideoFrameData(pixelBuffer: pixelBuffer, rotation: frame.rotation)
        }
        guard let y = frame.y, let u = frame.u, let v = frame.v, frame.width > 0, frame.height > 0 else {
            return nil
        }
        let height = Int(frame.height)
        let chromaHeight = (height + 1) / 2
        return OngoingGroupCallContext.VideoFrameData(
            i420Width: Int(frame.width),
            height: height,
            y: Data(bytes: y, count: Int(frame.strideY) * height),
            strideY: Int(frame.strideY),
            u: Data(bytes: u, count: Int(frame.strideU) * chromaHeight),
            strideU: Int(frame.strideU),
            v: Data(bytes: v, count: Int(frame.strideV) * chromaHeight),
            strideV: Int(frame.strideV),
            rotation: frame.rotation
        )
    }
}
#endif
