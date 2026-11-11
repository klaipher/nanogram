#if os(macOS)
import XCTest
import SwiftSignalKit
import TelegramApi
@testable import TelegramCore

final class AudioFileTranscriptionTests: XCTestCase {
    func testUploadLimitsAndDurationBoundaries() {
        let ogg = Data([0x4f, 0x67, 0x67, 0x53])
        XCTAssertNil(validateAudioFileTranscription(data: ogg, duration: 1))
        XCTAssertNil(validateAudioFileTranscription(data: ogg, duration: 1800))
        XCTAssertEqual(validateAudioFileTranscription(data: ogg, duration: 0.99), .invalidAudio)
        XCTAssertEqual(validateAudioFileTranscription(data: ogg, duration: .nan), .invalidAudio)
        XCTAssertEqual(validateAudioFileTranscription(data: ogg, duration: .infinity), .invalidAudio)
        XCTAssertEqual(validateAudioFileTranscription(data: ogg, duration: 1800.01), .tooLong)
        XCTAssertEqual(validateAudioFileTranscription(data: Data(), duration: 3), .invalidAudio)
        var maximum = ogg
        maximum.append(Data(count: 1024 * 1024 - 4))
        XCTAssertNil(validateAudioFileTranscription(data: maximum, duration: 3))
        maximum.append(0)
        XCTAssertEqual(validateAudioFileTranscription(data: maximum, duration: 3), .tooBig)
    }

    func testErrorsPreserveServerGates() {
        let values: [(String, AudioFileTranscriptionError)] = [
            ("INPUT_FILE_INVALID", .inputFileInvalid), ("AUDIO_FILE_TOO_BIG", .tooBig),
            ("AUDIO_FILE_INVALID", .invalidAudio), ("MSG_VOICE_TOO_LONG", .tooLong),
            ("PREMIUM_ACCOUNT_REQUIRED", .premiumRequired), ("FLOOD_WAIT_60", .limitExceeded(60)),
            ("TRANSCRIPTION_FAILED", .failed), ("FLOOD_WAIT_bad", .generic), ("OTHER", .generic)
        ]
        for (description, expected) in values { XCTAssertEqual(audioFileTranscriptionError(description), expected) }
    }

    func testUpdateConstructorUsesTranscriptionIdAndPendingFlag() {
        let updates: [Api.Update] = [
            .updateTranscribedAudioFile(.init(flags: 1, transcriptionId: 41, text: "partial")),
            .updateTranscribedAudioFile(.init(flags: 0, transcriptionId: 42, text: "final"))
        ]
        XCTAssertEqual(audioFileTranscriptionsFromUpdates(updates), [
            AudioFileTranscription(id: 41, text: "partial", isPending: true),
            AudioFileTranscription(id: 42, text: "final", isPending: false)
        ])
    }

    func testImmediateCachedResponseCompletes() {
        let done = expectation(description: "done")
        let value = AudioFileTranscription(id: 1, text: "cached", isPending: false)
        var received: [AudioFileTranscription] = []
        let disposable = resolveAudioFileTranscription(request: .single(value), updates: .never()).start(next: { received.append($0) }, completed: { done.fulfill() })
        wait(for: [done], timeout: 3)
        XCTAssertEqual(received, [value])
        disposable.dispose()
    }

    func testPendingIgnoresOtherIdsAndCompletesOnMatchingFinal() {
        let pending = expectation(description: "pending")
        let done = expectation(description: "done")
        let updates = ValuePipe<AudioFileTranscription>()
        var received: [AudioFileTranscription] = []
        let disposable = resolveAudioFileTranscription(request: .single(.init(id: 9, text: "", isPending: true)), updates: updates.signal()).start(next: { value in
            received.append(value)
            if value.isPending { pending.fulfill() }
        }, completed: { done.fulfill() })
        wait(for: [pending], timeout: 3)
        updates.putNext(.init(id: 8, text: "wrong", isPending: false))
        updates.putNext(.init(id: 9, text: "right", isPending: false))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(received.map(\.text), ["", "right"])
        disposable.dispose()
    }

    func testFinalUpdateBeforeResponseCannotBeLostOrRegressed() {
        let request = ValuePipe<AudioFileTranscription>()
        let updates = ValuePipe<AudioFileTranscription>()
        let done = expectation(description: "done")
        var received: [AudioFileTranscription] = []
        let disposable = resolveAudioFileTranscription(request: request.signal() |> castError(AudioFileTranscriptionError.self), updates: updates.signal()).start(next: { received.append($0) }, completed: { done.fulfill() })
        updates.putNext(.init(id: 4, text: "final", isPending: false))
        updates.putNext(.init(id: 4, text: "older partial", isPending: true))
        request.putNext(.init(id: 4, text: "", isPending: true))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(received, [.init(id: 4, text: "final", isPending: false)])
        disposable.dispose()
    }

    func testCancellationDisposesRequestAndUpdateSubscriptions() {
        let requestDisposed = expectation(description: "request disposed")
        let updatesDisposed = expectation(description: "updates disposed")
        let request = Signal<AudioFileTranscription, AudioFileTranscriptionError> { _ in
            return ActionDisposable { requestDisposed.fulfill() }
        }
        let updates = Signal<AudioFileTranscription, NoError> { _ in
            return ActionDisposable { updatesDisposed.fulfill() }
        }
        let disposable = resolveAudioFileTranscription(request: request, updates: updates).start()
        disposable.dispose()
        wait(for: [requestDisposed, updatesDisposed], timeout: 3)
    }
}
#endif
