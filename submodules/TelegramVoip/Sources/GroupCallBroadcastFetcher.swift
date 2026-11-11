#if os(macOS)
import Foundation
import SwiftSignalKit
import TgVoipWebrtc
import TelegramCore
import BroadcastPlayback

public final class GroupCallBroadcastFetcher {
    private let source: BroadcastPartSource

    init(source: BroadcastPartSource) {
        self.source = source
    }

    public convenience init(queue: Queue, audioStreamData: OngoingGroupCallContext.AudioStreamData) {
        self.init(source: NetworkBroadcastPartSource(queue: queue, engine: audioStreamData.engine, callId: audioStreamData.callId, accessHash: audioStreamData.accessHash, isExternalStream: audioStreamData.isExternalStream))
    }

    public func edge(completion: @escaping (BroadcastEdgeOutcome) -> Void) -> Disposable {
        return self.source.requestTime(completion: { timestampMs in
            if timestampMs > 0 {
                completion(.edge(reportedMs: timestampMs))
            } else {
                completion(.failed)
            }
        })
    }

    public func load(_ request: BroadcastPartRequest, completion: @escaping (BroadcastPartOutcome, Data?) -> Void) -> Disposable {
        let subject: BroadcastPartSubject
        switch request.kind {
        case .audio:
            subject = .audio
        case let .video(channelId, quality):
            subject = .video(channelId: channelId, quality: GroupCallBroadcastFetcher.quality(quality))
        case let .unified(quality):
            subject = .video(channelId: 1, quality: GroupCallBroadcastFetcher.quality(quality))
        }
        return self.source.requestPart(timestampMilliseconds: request.timestampMs, durationMilliseconds: BroadcastLivePosition.partDurationMs, subject: subject, completion: { part in
            switch part.status {
            case .success:
                let data = part.oggData
                completion(.data(bytes: Int64(data.count), responseTimestamp: part.responseTimestamp, info: GroupCallBroadcastFetcher.info(for: request, data: data)), data)
            case .notReady:
                completion(.notReady, nil)
            case .resyncNeeded:
                completion(.resyncNeeded(responseTimestamp: part.responseTimestamp), nil)
            @unknown default:
                completion(.notReady, nil)
            }
        }, rejoinNeeded: {
            completion(.rejoinNeeded, nil)
        })
    }

    private static func quality(_ quality: BroadcastQuality) -> OngoingGroupCallContext.VideoChannel.Quality {
        switch quality {
        case .thumbnail:
            return .thumbnail
        case .medium:
            return .medium
        case .full:
            return .full
        }
    }

    public static func info(for request: BroadcastPartRequest, data: Data) -> BroadcastPartInfo {
        guard case .audio = request.kind, !data.isEmpty else {
            return BroadcastPartInfo()
        }
        var info = BroadcastListenerAudioInfo()
        let parsed = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return BroadcastListenerAudioReadInfo(base, raw.count, &info)
        }
        guard parsed else {
            return BroadcastPartInfo()
        }
        var channels: [String: Int32] = [:]
        withUnsafeBytes(of: &info.endpoints) { raw in
            let endpoints = raw.bindMemory(to: BroadcastListenerAudioEndpoint.self)
            for index in 0 ..< min(info.endpointCount, endpoints.count) {
                var endpoint = endpoints[index]
                let name = withUnsafeBytes(of: &endpoint.endpointId) { bytes -> String in
                    let length = bytes.firstIndex(of: 0) ?? bytes.count
                    return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[0 ..< length]), as: UTF8.self)
                }
                channels[name] = endpoint.channelId
            }
        }
        return BroadcastPartInfo(videoChannels: channels, audioDurationMs: Int(info.durationMs))
    }
}
#endif
