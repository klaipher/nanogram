import AVFoundation
import Foundation
import OpusKit

@MainActor
protocol VoicePlaybackBackend: AnyObject {
    func prepare() throws
    func play(buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void) throws
    func pause()
    func resume()
    func stop()
    /// Stops the audio hardware (a running engine keeps it on even when nothing plays).
    func releaseHardware()
    var elapsed: Double { get }
    var lastBufferDuration: Double { get }

    // Streaming playback (WATCH-MEM-1): successive buffers on one player node. Backends that only play a
    // whole buffer keep the defaults below, and the controller never calls them.
    /// Starts an empty stream; `completion` fires once every enqueued buffer has played after `finishStream`.
    func beginStream(format: AVAudioFormat, expectedDuration: Double, completion: @escaping @MainActor () -> Void) throws
    func enqueue(buffer: AVAudioPCMBuffer)
    /// No more buffers will follow.
    func finishStream()
    /// Buffers scheduled but not yet played.
    var queuedBufferCount: Int { get }
}

extension VoicePlaybackBackend {
    func beginStream(format: AVAudioFormat, expectedDuration: Double, completion: @escaping @MainActor () -> Void) throws {
        throw NSError(domain: "VoicePlaybackBackend", code: 1)
    }
    func enqueue(buffer: AVAudioPCMBuffer) {}
    func finishStream() {}
    var queuedBufferCount: Int { 0 }
}

/// A voice note decoded in pieces; calls are made one at a time.
protocol VoiceChunkStream: AnyObject, Sendable {
    /// Length in seconds when the file says so.
    var totalDuration: Double? { get }
    /// The next chunk of at most about `maxFrames` frames; nil at the end.
    func nextChunk(maxFrames: Int) async throws -> DecodedOpus?
}

protocol VoiceDecoder: Sendable {
    func decodePCM(url: URL) async throws -> DecodedOpus
    /// Opens the file for chunked decoding; nil when the decoder only does whole files.
    func openChunks(url: URL) async throws -> VoiceChunkStream?
}

extension VoiceDecoder {
    func openChunks(url: URL) async throws -> VoiceChunkStream? { nil }
}

enum VoiceGlyph: Equatable {
    case play
    case pause
    case spinner
    case error
}

@Observable @MainActor
final class VoicePlaybackController {

    enum State: Equatable {
        case idle
        case preparing(voiceFileId: Int, progress: Double)
        case playing(voiceFileId: Int)
        case paused(voiceFileId: Int)
        case failed(voiceFileId: Int, message: String)
    }

    private(set) var state: State = .idle
    /// Observable progress tick that drives the bubble's waveform fill during
    /// playback. Updated by `startTicker(tok:)` while in `.playing`.
    private(set) var currentProgress: Double = 0

    private let backend: VoicePlaybackBackend
    private let decoder: VoiceDecoder
    /// WATCH-MEM-1: decode in chunks and play after the first one (flag `chunkedVoiceDecode`).
    private let chunkedDecode: Bool

    /// The first chunk is short so sound starts within ~100 ms of the tap; later chunks are 1 s.
    static let firstChunkFrames = 4_800
    static let chunkFrames = 48_000
    /// Buffers kept scheduled ahead of the playhead.
    static let maxBuffersInFlight = 3

    /// Identifies which decode/playback any pending completion belongs to.
    private var activeTok: Int = 0
    private var tickerTask: Task<Void, Never>? = nil
    private var decodeTask: Task<Void, Never>? = nil

    init(backend: VoicePlaybackBackend, decoder: VoiceDecoder, chunkedDecode: Bool = false) {
        self.backend = backend
        self.decoder = decoder
        self.chunkedDecode = chunkedDecode
    }

    func isActive(_ voiceFileId: Int) -> Bool {
        switch state {
        case .preparing(let id, _), .playing(let id), .paused(let id), .failed(let id, _):
            return id == voiceFileId
        case .idle:
            return false
        }
    }

    func glyph(for voiceFileId: Int) -> VoiceGlyph {
        switch state {
        case .preparing(let id, _) where id == voiceFileId: return .spinner
        case .playing(let id) where id == voiceFileId:      return .pause
        case .paused(let id) where id == voiceFileId:       return .play
        case .failed(let id, _) where id == voiceFileId:    return .error
        default:                                            return .play
        }
    }

    func progress(for voiceFileId: Int) -> Double {
        guard isActive(voiceFileId) else { return 0 }
        return currentProgress
    }

    func tearDown() {
        activeTok &+= 1
        tickerTask?.cancel()
        tickerTask = nil
        decodeTask?.cancel()
        decodeTask = nil
        currentProgress = 0
        backend.stop()
        backend.releaseHardware()
        state = .idle
    }

    /// Entry point the bubble calls. If `note.localPath` is nil the controller
    /// transitions to `.preparing` and waits for the caller to call
    /// `resumeIfReady(note:)` once a path arrives.
    func toggle(note: VoiceNoteVisual) {
        switch state {
        case .playing(let id) where id == note.voiceFileId:
            backend.pause()
            tickerTask?.cancel()
            tickerTask = nil
            state = .paused(voiceFileId: id)
            return
        case .paused(let id) where id == note.voiceFileId:
            backend.resume()
            state = .playing(voiceFileId: id)
            startTicker(tok: activeTok)
            return
        case .preparing(let id, _) where id == note.voiceFileId:
            // Second tap during preparing = cancel.
            tearDown()
            return
        default:
            // Switch active (or fresh start).
            tearDown()
        }
        guard let path = note.localPath else {
            state = .preparing(voiceFileId: note.voiceFileId, progress: 0)
            return
        }
        startPlayback(note: note, path: path)
    }

    /// Called by ChatHistoryStore when a fileSnapshot update lands for a voice
    /// that's currently in `.preparing`. Advances to `.playing` if the path is
    /// now available.
    func resumeIfReady(note: VoiceNoteVisual) {
        guard case .preparing(let id, _) = state, id == note.voiceFileId else { return }
        guard let path = note.localPath else { return }
        startPlayback(note: note, path: path)
    }

    /// Called by ChatHistoryStore with download progress (0…1) while preparing.
    func updateDownloadProgress(voiceFileId: Int, progress: Double) {
        guard case .preparing(let id, _) = state, id == voiceFileId else { return }
        state = .preparing(voiceFileId: id, progress: progress)
    }

    // MARK: - Private

    private func startPlayback(note: VoiceNoteVisual, path: String) {
        activeTok &+= 1
        let tok = activeTok
        state = .preparing(voiceFileId: note.voiceFileId, progress: 1)

        let url = URL(fileURLWithPath: path)
        let decoder = self.decoder
        decodeTask?.cancel()
        if chunkedDecode {
            decodeTask = Task { [weak self] in
                await self?.runChunkedPlayback(tok: tok, note: note, url: url)
            }
            return
        }
        decodeTask = Task { [weak self] in
            do {
                let decoded = try await decoder.decodePCM(url: url)
                self?.handleDecoded(tok: tok, note: note, decoded: decoded)
            } catch {
                self?.handleDecodeError(tok: tok, note: note, error: error)
            }
        }
    }

    private func handleDecoded(tok: Int, note: VoiceNoteVisual, decoded: DecodedOpus) {
        guard tok == activeTok else { return }
        do {
            try backend.prepare()
            try backend.play(buffer: decoded.pcm) { [weak self] in
                self?.handlePlaybackEnded(tok: tok, voiceFileId: note.voiceFileId)
            }
            state = .playing(voiceFileId: note.voiceFileId)
            startTicker(tok: tok)
        } catch {
            state = .failed(voiceFileId: note.voiceFileId, message: "Audio unavailable")
        }
    }

    // MARK: - Chunked playback

    /// Opens the file, plays the first chunk as soon as it is decoded and keeps up to
    /// `maxBuffersInFlight` buffers scheduled while the next ones decode. A decoder without chunk support
    /// falls back to the whole-file path.
    private func runChunkedPlayback(tok: Int, note: VoiceNoteVisual, url: URL) async {
        let decoder = self.decoder
        do {
            guard let stream = try await decoder.openChunks(url: url) else {
                let decoded = try await decoder.decodePCM(url: url)
                handleDecoded(tok: tok, note: note, decoded: decoded)
                return
            }
            guard let first = try await stream.nextChunk(maxFrames: Self.firstChunkFrames) else {
                handleDecodeError(tok: tok, note: note, error: CancellationError())
                return
            }
            guard tok == activeTok else { return }
            do {
                try backend.prepare()
                try backend.beginStream(
                    format: first.pcm.format,
                    expectedDuration: stream.totalDuration ?? Double(note.duration)
                ) { [weak self] in
                    self?.handlePlaybackEnded(tok: tok, voiceFileId: note.voiceFileId)
                }
            } catch {
                state = .failed(voiceFileId: note.voiceFileId, message: "Audio unavailable")
                return
            }
            backend.enqueue(buffer: first.pcm)
            state = .playing(voiceFileId: note.voiceFileId)
            startTicker(tok: tok)
            await pumpChunks(tok: tok, stream: stream)
        } catch {
            if !Task.isCancelled { handleDecodeError(tok: tok, note: note, error: error) }
        }
    }

    private func pumpChunks(tok: Int, stream: VoiceChunkStream) async {
        while !Task.isCancelled, tok == activeTok {
            if backend.queuedBufferCount >= Self.maxBuffersInFlight {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            do {
                let chunk = try await stream.nextChunk(maxFrames: Self.chunkFrames)
                guard tok == activeTok else { return }
                guard let chunk else {
                    backend.finishStream()
                    return
                }
                backend.enqueue(buffer: chunk.pcm)
            } catch {
                // A bad packet mid-note ends the note where it is rather than failing what already played.
                guard tok == activeTok else { return }
                backend.finishStream()
                return
            }
        }
    }

    private func handleDecodeError(tok: Int, note: VoiceNoteVisual, error: Error) {
        guard tok == activeTok else { return }
        state = .failed(voiceFileId: note.voiceFileId, message: "Could not play voice note")
    }

    private func handlePlaybackEnded(tok: Int, voiceFileId: Int) {
        guard tok == activeTok else { return }
        tickerTask?.cancel()
        tickerTask = nil
        currentProgress = 0
        backend.stop()
        backend.releaseHardware()
        state = .idle
    }

    /// Drives `currentProgress` updates at 20 Hz so the bubble's waveform fill
    /// is observable. Stops when the active token changes or state leaves
    /// `.playing`.
    private func startTicker(tok: Int) {
        tickerTask?.cancel()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard tok == self.activeTok else { return }
                guard case .playing = self.state else { return }
                let total = self.backend.lastBufferDuration
                if total > 0 {
                    self.currentProgress = min(1, max(0, self.backend.elapsed / total))
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            }
        }
    }
}

// MARK: - Production wiring

@MainActor
final class AVEngineBackend: VoicePlaybackBackend {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private var connectedFormat: AVAudioFormat?
    private(set) var lastBufferDuration: Double = 0
    private var lastSampleRate: Double = 48000
    private var pendingCompletion: (@MainActor () -> Void)?
    // Streaming state; `streamGeneration` invalidates the completions of buffers from an earlier stream.
    private var streamGeneration = 0
    private var scheduledBuffers = 0
    private var playedBuffers = 0
    private var scheduledFrames = 0.0
    private var streamFinished = false

    var queuedBufferCount: Int { scheduledBuffers - playedBuffers }

    var elapsed: Double {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return 0
        }
        return Double(playerTime.sampleTime) / lastSampleRate
    }

    func prepare() throws {
        if !attached {
            engine.attach(player)
            attached = true
        }
    }

    func play(buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void) throws {
        // AVAudioPlayerNode rejects buffers whose format differs from the player's
        // output connection format. Telegram voice notes are typically mono; the
        // smoke-test fixture is stereo. Reconnect on every format change so both
        // sources play back without raising NSInternalInconsistencyException.
        let bufFmt = buffer.format
        connectIfNeeded(bufFmt)
        if !engine.isRunning {
            try engine.start()
        }
        lastSampleRate = bufFmt.sampleRate
        lastBufferDuration = Double(buffer.frameLength) / lastSampleRate
        pendingCompletion = completion
        let captured = completion
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            // AVAudioEngine fires this on a non-main queue.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.pendingCompletion != nil else { return }
                self.pendingCompletion = nil
                captured()
            }
        }
        player.play()
    }

    func beginStream(format: AVAudioFormat, expectedDuration: Double, completion: @escaping @MainActor () -> Void) throws {
        connectIfNeeded(format)
        if !engine.isRunning {
            try engine.start()
        }
        streamGeneration += 1
        scheduledBuffers = 0
        playedBuffers = 0
        scheduledFrames = 0
        streamFinished = false
        lastSampleRate = format.sampleRate
        lastBufferDuration = expectedDuration
        pendingCompletion = completion
        player.play()
    }

    func enqueue(buffer: AVAudioPCMBuffer) {
        scheduledBuffers += 1
        scheduledFrames += Double(buffer.frameLength)
        lastBufferDuration = max(lastBufferDuration, scheduledFrames / lastSampleRate)
        let generation = streamGeneration
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            // AVAudioEngine fires this on a non-main queue.
            Task { @MainActor [weak self] in self?.bufferPlayed(generation: generation) }
        }
    }

    func finishStream() {
        streamFinished = true
        completeStreamIfDone()
    }

    private func bufferPlayed(generation: Int) {
        guard generation == streamGeneration else { return }
        playedBuffers += 1
        completeStreamIfDone()
    }

    private func completeStreamIfDone() {
        guard streamFinished, playedBuffers >= scheduledBuffers, let done = pendingCompletion else { return }
        pendingCompletion = nil
        done()
    }

    private func connectIfNeeded(_ bufFmt: AVAudioFormat) {
        if connectedFormat == nil || connectedFormat?.isEqual(bufFmt) == false {
            if connectedFormat != nil {
                engine.disconnectNodeOutput(player)
            }
            engine.connect(player, to: engine.mainMixerNode, format: bufFmt)
            connectedFormat = bufFmt
        }
    }

    func pause()  { player.pause() }
    func resume() { player.play() }

    func stop() {
        pendingCompletion = nil
        streamGeneration += 1
        scheduledBuffers = 0
        playedBuffers = 0
        streamFinished = false
        player.stop()
        // The engine stays up while paused; the controller calls `releaseHardware` when a
        // note ends, on a switch to another note and when the chat closes.
    }

    /// Stops the engine entirely; `play` starts it again. Safe to call repeatedly.
    func releaseHardware() {
        player.stop()
        if engine.isRunning { engine.stop() }
    }
}

struct OpusDecoderAdapter: VoiceDecoder {
    func decodePCM(url: URL) async throws -> DecodedOpus {
        try await Task.detached(priority: .userInitiated) {
            try OpusKit.OpusDecoder.decodePCM(url: url)
        }.value
    }

    func openChunks(url: URL) async throws -> VoiceChunkStream? {
        try await Task.detached(priority: .userInitiated) {
            OpusChunkStream(decoder: try OpusKit.OpusChunkedDecoder(url: url))
        }.value
    }
}

/// Chunked decoding for one voice note. The controller awaits each chunk before asking for the next, so the
/// decoder (which is not thread-safe) is never used by two tasks at once.
final class OpusChunkStream: VoiceChunkStream, @unchecked Sendable {
    private let decoder: OpusKit.OpusChunkedDecoder

    init(decoder: OpusKit.OpusChunkedDecoder) {
        self.decoder = decoder
    }

    var totalDuration: Double? { decoder.totalDuration }

    func nextChunk(maxFrames: Int) async throws -> DecodedOpus? {
        try await Task.detached(priority: .userInitiated) { [decoder] in
            try decoder.nextChunk(maxFrames: maxFrames).map { DecodedOpus(pcm: $0) }
        }.value
    }
}
