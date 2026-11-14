import AVFoundation
import OpusKit
import XCTest
@testable import tgwatch_Watch_App

/// WATCH-MEM-1: with `chunkedDecode` the first chunk starts playback and later chunks are kept a few buffers
/// ahead of the playhead.
@MainActor
final class CoreVoiceChunkedPlaybackTests: XCTestCase {
    private func note() -> VoiceNoteVisual {
        VoiceNoteVisual(voiceFileId: 42, duration: 4, mimeType: "audio/ogg", waveform: Data(), caption: "", localPath: "/tmp/voice.ogg")
    }

    private func makeController(
        chunks: Int,
        failAfter: Int? = nil,
        chunked: Bool = true,
        streaming: Bool = true
    ) -> (VoicePlaybackController, StreamingFakeBackend, StreamingFakeDecoder) {
        let backend = StreamingFakeBackend()
        let decoder = StreamingFakeDecoder(chunks: chunks, failAfter: failAfter, supportsStreaming: streaming)
        return (VoicePlaybackController(backend: backend, decoder: decoder, chunkedDecode: chunked), backend, decoder)
    }

    func testPlaybackStartsAfterTheFirstChunkWithoutDecodingTheRest() async {
        let (controller, backend, decoder) = makeController(chunks: 10)
        controller.toggle(note: note())
        let playing = await coreWait { controller.state == .playing(voiceFileId: 42) }
        XCTAssertTrue(playing)
        XCTAssertEqual(backend.begun, 1)
        XCTAssertGreaterThanOrEqual(backend.enqueued, 1)
        XCTAssertEqual(decoder.requestedSizes.first, VoicePlaybackController.firstChunkFrames, "a short first chunk")
        // Pending buffers fill to the in-flight cap and the decoder is not asked for more.
        let capped = await coreWait { backend.enqueued == VoicePlaybackController.maxBuffersInFlight }
        XCTAssertTrue(capped)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(backend.enqueued, VoicePlaybackController.maxBuffersInFlight)
        XCTAssertEqual(backend.finished, 0)
        controller.tearDown()
    }

    func testPlayedBuffersLetTheNextChunksIn() async {
        let (controller, backend, _) = makeController(chunks: 6)
        controller.toggle(note: note())
        _ = await coreWait { backend.enqueued == VoicePlaybackController.maxBuffersInFlight }
        backend.queued = 0   // the player consumed them
        let more = await coreWait { backend.enqueued > VoicePlaybackController.maxBuffersInFlight }
        XCTAssertTrue(more)
        controller.tearDown()
    }

    func testStreamEndMarksTheBackendFinishedAndCompletionReturnsToIdle() async {
        let (controller, backend, _) = makeController(chunks: 2)
        controller.toggle(note: note())
        let finished = await coreWait { backend.finished == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(backend.enqueued, 2)
        let stopsBefore = backend.stopCount
        backend.completion?()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(backend.stopCount, stopsBefore + 1)
        XCTAssertGreaterThanOrEqual(backend.releaseCount, 1, "hardware released when the note ends")
    }

    func testTearDownStopsFurtherDecoding() async {
        let (controller, backend, decoder) = makeController(chunks: 100)
        controller.toggle(note: note())
        _ = await coreWait { backend.enqueued >= 1 }
        controller.tearDown()
        let enqueuedAtStop = backend.enqueued
        let requestedAtStop = decoder.requestedSizes.count
        backend.queued = 0
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(backend.enqueued, enqueuedAtStop)
        XCTAssertEqual(decoder.requestedSizes.count, requestedAtStop)
        XCTAssertEqual(controller.state, .idle)
    }

    func testMidStreamDecodeErrorEndsTheNoteWhereItIsInsteadOfFailingIt() async {
        let (controller, backend, _) = makeController(chunks: 10, failAfter: 2)
        controller.toggle(note: note())
        let finished = await coreWait { backend.finished == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(controller.state, .playing(voiceFileId: 42))
        controller.tearDown()
    }

    func testExpectedDurationComesFromTheFileWhenKnown() async {
        let (controller, backend, _) = makeController(chunks: 2)
        controller.toggle(note: note())
        _ = await coreWait { backend.begun == 1 }
        XCTAssertEqual(backend.expectedDuration, 2.5)
        controller.tearDown()
    }

    func testAnEmptyFileFails() async {
        let (controller, _, _) = makeController(chunks: 0)
        controller.toggle(note: note())
        let failed = await coreWait { controller.state == .failed(voiceFileId: 42, message: "Could not play voice note") }
        XCTAssertTrue(failed)
    }

    func testFlagOffKeepsTheWholeFilePath() async {
        let (controller, backend, decoder) = makeController(chunks: 10, chunked: false)
        controller.toggle(note: note())
        let playing = await coreWait { controller.state == .playing(voiceFileId: 42) }
        XCTAssertTrue(playing)
        XCTAssertEqual(backend.begun, 0)
        XCTAssertEqual(backend.wholeBufferPlays, 1)
        XCTAssertEqual(decoder.openCount, 0)
    }

    func testDecoderWithoutChunkSupportFallsBackToTheWholeFile() async {
        let (controller, backend, _) = makeController(chunks: 10, streaming: false)
        controller.toggle(note: note())
        let playing = await coreWait { controller.state == .playing(voiceFileId: 42) }
        XCTAssertTrue(playing)
        XCTAssertEqual(backend.begun, 0)
        XCTAssertEqual(backend.wholeBufferPlays, 1)
    }

    func testFlagShipsOff() {
        XCTAssertFalse(WatchFeature.chunkedVoiceDecode.defaultValue)
    }
}

@MainActor
final class StreamingFakeBackend: VoicePlaybackBackend {
    var elapsed: Double = 0
    var lastBufferDuration: Double = 1
    var queued = 0
    private(set) var begun = 0
    private(set) var enqueued = 0
    private(set) var finished = 0
    private(set) var stopCount = 0
    private(set) var releaseCount = 0
    private(set) var wholeBufferPlays = 0
    private(set) var expectedDuration: Double?
    private(set) var completion: (@MainActor () -> Void)?

    var queuedBufferCount: Int { queued }
    func prepare() throws {}
    func play(buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void) throws {
        wholeBufferPlays += 1
        self.completion = completion
    }
    func beginStream(format: AVAudioFormat, expectedDuration: Double, completion: @escaping @MainActor () -> Void) throws {
        begun += 1
        self.expectedDuration = expectedDuration
        self.completion = completion
    }
    func enqueue(buffer: AVAudioPCMBuffer) {
        enqueued += 1
        queued += 1
    }
    func finishStream() { finished += 1 }
    func pause() {}
    func resume() {}
    func stop() { stopCount += 1 }
    func releaseHardware() { releaseCount += 1 }
}

final class StreamingFakeStream: VoiceChunkStream, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var served = 0
    private let failAfter: Int?
    private let onRequest: @Sendable (Int) -> Void
    let totalDuration: Double? = 2.5

    init(chunks: Int, failAfter: Int?, onRequest: @escaping @Sendable (Int) -> Void) {
        remaining = chunks
        self.failAfter = failAfter
        self.onRequest = onRequest
    }

    func nextChunk(maxFrames: Int) async throws -> DecodedOpus? {
        onRequest(maxFrames)
        let (isEmpty, shouldFail): (Bool, Bool) = lock.withLock {
            if let failAfter, served >= failAfter { return (false, true) }
            if remaining == 0 { return (true, false) }
            remaining -= 1
            served += 1
            return (false, false)
        }
        if shouldFail { throw NSError(domain: "test", code: 1) }
        if isEmpty { return nil }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480) else { return nil }
        buffer.frameLength = 480
        return DecodedOpus(pcm: buffer)
    }
}

final class StreamingFakeDecoder: VoiceDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []
    private var opens = 0
    private let chunks: Int
    private let failAfter: Int?
    private let supportsStreaming: Bool

    var requestedSizes: [Int] { lock.withLock { sizes } }
    var openCount: Int { lock.withLock { opens } }

    init(chunks: Int, failAfter: Int?, supportsStreaming: Bool) {
        self.chunks = chunks
        self.failAfter = failAfter
        self.supportsStreaming = supportsStreaming
    }

    func decodePCM(url: URL) async throws -> DecodedOpus {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480) else {
            throw NSError(domain: "test", code: 2)
        }
        buffer.frameLength = 480
        return DecodedOpus(pcm: buffer)
    }

    func openChunks(url: URL) async throws -> VoiceChunkStream? {
        guard supportsStreaming else { return nil }
        lock.withLock { opens += 1 }
        return StreamingFakeStream(chunks: chunks, failAfter: failAfter) { [weak self] size in
            self?.lock.withLock { self?.sizes.append(size) }
        }
    }
}
