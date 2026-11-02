import AVFoundation
import XCTest
@testable import tgwatch_Watch_App

@MainActor
final class CoreVoicePlaybackTests: XCTestCase {
    private func note() -> VoiceNoteVisual {
        VoiceNoteVisual(voiceFileId: 42, duration: 1, mimeType: "audio/ogg", waveform: Data(), caption: "", localPath: "/tmp/voice.ogg")
    }

    /// A running AVAudioEngine keeps the audio hardware on; it must stop when the note ends,
    /// not only when the chat closes.
    func testPlaybackEndReleasesAudioHardware() async {
        let backend = CoreFakeVoiceBackend()
        let controller = VoicePlaybackController(backend: backend, decoder: CoreFakeVoiceDecoder())
        controller.toggle(note: note())
        let playing = await coreWait { controller.state == .playing(voiceFileId: 42) }
        XCTAssertTrue(playing)
        let releasedBeforeEnd = backend.releaseCount

        backend.completion?()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(backend.releaseCount, releasedBeforeEnd + 1)
    }

    func testTearDownReleasesAudioHardware() {
        let backend = CoreFakeVoiceBackend()
        let controller = VoicePlaybackController(backend: backend, decoder: CoreFakeVoiceDecoder())
        controller.tearDown()
        XCTAssertEqual(backend.releaseCount, 1)
    }
}

@MainActor
private final class FailingRecordingBackend: RecordingBackend {
    private(set) var abortCount = 0
    func ensurePermission() async -> RecordPermission { .granted }
    func begin(onLevel: @escaping @MainActor (Float) -> Void) throws {
        throw NSError(domain: "test", code: 1)
    }
    func finish() async throws -> VoiceRecordingDraft { throw NSError(domain: "test", code: 2) }
    func abort() { abortCount += 1 }
}

@MainActor
final class CoreVoiceRecorderTests: XCTestCase {
    /// `begin` can fail after activating the record session; the recorder must undo it.
    func testFailedStartReleasesTheBackend() async {
        let backend = FailingRecordingBackend()
        let recorder = VoiceRecorder(backend: backend)
        await recorder.start()
        XCTAssertEqual(recorder.state, .failed("Couldn't start microphone"))
        XCTAssertEqual(backend.abortCount, 1)
    }
}

/// AVAudioEngine calls the tap on its render thread.
final class CoreRecordingTapTests: XCTestCase {
    func testTapBlockRunsOffTheMainThread() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tap-\(UUID().uuidString).ogg")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try OpusOggRecordingSink(outputURL: url, inputFormat: format)
        let level = expectation(description: "level reported on main")
        let tap = AVRecordingBackend.makeTapBlock(sink: sink) { value in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertGreaterThan(value, 0)
            level.fulfill()
        }

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<1024 { samples[i] = 0.5 * sinf(Float(i) * 0.2) }
        // AVFoundation types are not Sendable; the render thread is the only user here.
        let time = AVAudioTime(sampleTime: 0, atRate: 16_000)
        nonisolated(unsafe) let unsafeBuffer = buffer
        nonisolated(unsafe) let unsafeTap = tap
        DispatchQueue(label: "test.audio.render").async {
            unsafeTap(unsafeBuffer, time)
        }
        wait(for: [level], timeout: 2)
        sink.cancel()
    }
}

/// Music downloads only when tapped (a track is MBs; scrolling past a channel's posts used to
/// download each in full), and a tap that is taken back stops its download.
@MainActor
final class CoreAudioDownloadTests: XCTestCase {
    private func track(_ id: Int) -> AudioVisual {
        AudioVisual(audioFileId: id, duration: 180, title: "t", performer: "", albumArt: nil, caption: "", localPath: nil)
    }

    func testTapDownloadsAtPlaybackPriority() async {
        let loader = CoreFakeHistoryLoader()
        let store = CoreFixtures.historyStore(loader: loader)
        store.toggleAudioPlayback(track(9))
        XCTAssertEqual(store.audioPlayback.state, .preparing(audioFileId: 9))
        let requested = await coreWait { await loader.downloads.map(\.fileId) == [9] }
        XCTAssertTrue(requested)
        let priorities = await loader.downloads.map(\.priority)
        XCTAssertEqual(priorities, [2])
    }

    func testSecondTapWhilePreparingCancelsTheDownload() async {
        let loader = CoreFakeHistoryLoader()
        let store = CoreFixtures.historyStore(loader: loader)
        store.toggleAudioPlayback(track(9))
        store.toggleAudioPlayback(track(9))
        XCTAssertEqual(store.audioPlayback.state, .idle)
        let cancelled = await coreWait { await loader.cancelledDownloads == [9] }
        XCTAssertTrue(cancelled)
    }

    func testSwitchingTracksCancelsTheFirstDownload() async {
        let loader = CoreFakeHistoryLoader()
        let store = CoreFixtures.historyStore(loader: loader)
        store.toggleAudioPlayback(track(9))
        store.toggleAudioPlayback(track(10))
        XCTAssertEqual(store.audioPlayback.state, .preparing(audioFileId: 10))
        let settled = await coreWait {
            let cancelled = await loader.cancelledDownloads
            let downloads = await loader.downloads.map(\.fileId)
            return cancelled == [9] && downloads == [9, 10]
        }
        XCTAssertTrue(settled)
    }

    func testClosingTheChatCancelsAPendingTrack() async {
        let loader = CoreFakeHistoryLoader()
        let store = CoreFixtures.historyStore(loader: loader)
        store.toggleAudioPlayback(track(9))
        await store.stop()
        let cancelled = await coreWait { await loader.cancelledDownloads == [9] }
        XCTAssertTrue(cancelled)
    }

    /// The bubble no longer asks for its file when it scrolls into view.
    func testBubbleSourceHasNoViewportDownload() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tgwatch Watch App/Messages/AudioBubbleView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("onScrollVisibilityChange"))
        XCTAssertFalse(source.contains("requestFileDownload"))
    }
}
