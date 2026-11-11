#if os(macOS)
import Foundation
import os.log
import Postbox
import SwiftSignalKit
internal import TelegramApi

private let audioFileTranscriptionLog = OSLog(subsystem: "org.telegram.AudioFileTranscription", category: "Core")

public struct AudioFileTranscription: Equatable {
    public let id: Int64
    public let text: String
    public let isPending: Bool
}

public enum AudioFileTranscriptionError: Error, Equatable {
    case inputFileInvalid
    case tooBig
    case invalidAudio
    case tooLong
    case premiumRequired
    case limitExceeded(Int32)
    case failed
    case timedOut
    case generic
}

func audioFileTranscriptionError(_ description: String) -> AudioFileTranscriptionError {
    switch description {
    case "INPUT_FILE_INVALID": return .inputFileInvalid
    case "AUDIO_FILE_TOO_BIG": return .tooBig
    case "AUDIO_FILE_INVALID": return .invalidAudio
    case "MSG_VOICE_TOO_LONG": return .tooLong
    case "PREMIUM_ACCOUNT_REQUIRED": return .premiumRequired
    case "TRANSCRIPTION_FAILED": return .failed
    default:
        if description.hasPrefix("FLOOD_WAIT_"), let seconds = Int32(description.dropFirst("FLOOD_WAIT_".count)), seconds >= 0 {
            return .limitExceeded(seconds)
        }
        return .generic
    }
}

func validateAudioFileTranscription(data: Data, duration: Double) -> AudioFileTranscriptionError? {
    guard data.count <= 1024 * 1024 else { return .tooBig }
    guard duration.isFinite, duration >= 1 else { return .invalidAudio }
    guard duration <= 1800 else { return .tooLong }
    guard data.starts(with: [0x4f, 0x67, 0x67, 0x53]) else { return .invalidAudio }
    return nil
}

func audioFileTranscriptionsFromUpdates(_ updates: [Api.Update]) -> [AudioFileTranscription] {
    return updates.compactMap { update in
        guard case let .updateTranscribedAudioFile(value) = update else { return nil }
        os_log("pushed update pending=%{public}d characters=%{public}ld", log: audioFileTranscriptionLog, type: .default, value.flags & 1, value.text.utf16.count)
        return AudioFileTranscription(id: value.transcriptionId, text: value.text, isPending: value.flags & 1 != 0)
    }
}

func resolveAudioFileTranscription(request: Signal<AudioFileTranscription, AudioFileTranscriptionError>, updates: Signal<AudioFileTranscription, NoError>) -> Signal<AudioFileTranscription, AudioFileTranscriptionError> {
    return Signal { subscriber in
        let queue = Queue(name: "AudioFileTranscription")
        let cancelled = Atomic(value: false)
        let requestDisposable = MetaDisposable()
        let updatesDisposable = MetaDisposable()
        var transcriptionId: Int64?
        var earlyUpdates: [Int64: AudioFileTranscription] = [:]
        var finished = false
        let emit: (AudioFileTranscription) -> Void = { value in
            guard !finished, !cancelled.with({ $0 }) else { return }
            subscriber.putNext(value)
            if !value.isPending {
                finished = true
                subscriber.putCompletion()
                updatesDisposable.dispose()
            }
        }
        updatesDisposable.set((updates |> deliverOn(queue)).start(next: { value in
            guard !finished, !cancelled.with({ $0 }) else { return }
            if let transcriptionId {
                if value.id == transcriptionId {
                    emit(value)
                }
            } else {
                if earlyUpdates[value.id]?.isPending == false { return }
                earlyUpdates[value.id] = value
            }
        }))
        requestDisposable.set((request |> deliverOn(queue)).start(next: { value in
            guard !finished, !cancelled.with({ $0 }) else { return }
            transcriptionId = value.id
            if value.isPending, let updated = earlyUpdates[value.id] {
                emit(updated)
            } else {
                emit(value)
            }
            earlyUpdates.removeAll()
        }, error: { error in
            guard !finished, !cancelled.with({ $0 }) else { return }
            finished = true
            subscriber.putError(error)
            updatesDisposable.dispose()
        }))
        return ActionDisposable {
            _ = cancelled.swap(true)
            requestDisposable.dispose()
            updatesDisposable.dispose()
        }
    }
}

func _internal_transcribeAudioFile(account: Account, data: Data, duration: Double) -> Signal<AudioFileTranscription, AudioFileTranscriptionError> {
    os_log("request starting bytes=%{public}ld duration=%{public}.3f", log: audioFileTranscriptionLog, type: .default, data.count, duration)
    if let error = validateAudioFileTranscription(data: data, duration: duration) {
        return .fail(error)
    }
    return multipartUpload(network: account.network, postbox: account.postbox, source: .data(data), encrypt: false, tag: nil, hintFileSize: Int64(data.count), hintFileIsLarge: false, forceNoBigParts: true, useLargerParts: false, useMultiplexedRequests: false)
    |> mapError { _ in
        os_log("upload failed", log: audioFileTranscriptionLog, type: .error)
        return AudioFileTranscriptionError.generic
    }
    |> mapToSignal { value -> Signal<AudioFileTranscription, AudioFileTranscriptionError> in
        switch value {
        case .progress:
            return .complete()
        case let .inputFile(file):
            os_log("upload complete, calling transcribeAudioFile", log: audioFileTranscriptionLog, type: .default)
            let request = account.network.request(Api.functions.messages.transcribeAudioFile(file: file), automaticFloodWait: false)
            |> mapError { error in
                os_log("RPC error code=%{public}d reason=%{public}@", log: audioFileTranscriptionLog, type: .error, error.errorCode, error.errorDescription)
                return audioFileTranscriptionError(error.errorDescription)
            }
            |> mapToSignal { result -> Signal<AudioFileTranscription, AudioFileTranscriptionError> in
                guard case let .transcribedAudio(value) = result else { return .fail(.generic) }
                os_log("RPC response pending=%{public}d characters=%{public}ld", log: audioFileTranscriptionLog, type: .default, value.flags & 1, value.text.utf16.count)
                return account.postbox.transaction { transaction -> AudioFileTranscription in
                    _internal_updateAudioTranscriptionTrialState(transaction: transaction) { current in
                        if let remaining = value.trialRemainsNum, remaining > 0 {
                            return AudioTranscription.TrialState(remainingCount: remaining)
                        } else if let until = value.trialRemainsUntilDate {
                            return AudioTranscription.TrialState(cooldownUntilTime: until, remainingCount: 0)
                        }
                        return current.withUpdatedCooldownUntilTime(nil)
                    }
                    return AudioFileTranscription(id: value.transcriptionId, text: value.text, isPending: value.flags & 1 != 0)
                } |> castError(AudioFileTranscriptionError.self)
            }
            |> `catch` { error -> Signal<AudioFileTranscription, AudioFileTranscriptionError> in
                guard case let .limitExceeded(seconds) = error else { return .fail(error) }
                return account.postbox.transaction { transaction -> Void in
                    _internal_updateAudioTranscriptionTrialState(transaction: transaction) { _ in
                        let now = Int64(Date().timeIntervalSince1970)
                        return AudioTranscription.TrialState(cooldownUntilTime: Int32(clamping: now + Int64(seconds)), remainingCount: 0)
                    }
                }
                |> castError(AudioFileTranscriptionError.self)
                |> mapToSignal { _ -> Signal<AudioFileTranscription, AudioFileTranscriptionError> in
                    return .fail(error)
                }
            }
            return resolveAudioFileTranscription(request: request, updates: account.stateManager.audioFileTranscriptionUpdates())
        case .inputSecretFile:
            return .fail(.inputFileInvalid)
        }
    }
    |> timeout(120, queue: Queue.concurrentDefaultQueue(), alternate: .fail(.timedOut))
}

func _internal_getTranscriptionLanguages(account: Account, peerId: EnginePeer.Id?) -> Signal<[String], NoError> {
    if peerId?.namespace == Namespaces.Peer.SecretChat { return .single([]) }
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        return peerId.flatMap { transaction.getPeer($0).flatMap(apiInputPeer) }
    }
    |> mapToSignal { peer -> Signal<[String], NoError> in
        return account.network.request(Api.functions.messages.getTranscriptionLangs(flags: peer == nil ? 0 : 1, peer: peer), automaticFloodWait: false)
        |> map { Array($0.filter { !$0.isEmpty }.prefix(3)) }
        |> `catch` { _ in .single([]) }
    }
    |> timeout(2, queue: Queue.concurrentDefaultQueue(), alternate: .single([]))
}
#endif
