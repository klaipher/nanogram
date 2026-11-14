import AVFoundation
import Foundation
import OpusKit

/// Serial-queue bridge from AVAudioEngine tap buffers to an on-disk Ogg/Opus
/// file. Resamples each tap buffer to 48 kHz mono Float32 (on the audio thread),
/// then frames into 20 ms Opus frames, encodes, and muxes (on `queue`). Also
/// accumulates per-frame RMS for the outgoing waveform.
///
/// Thread model: `AVAudioConverter` and its reused output buffer are used ONLY on the
/// audio render thread (inside `append`, serialized by AVAudioEngine). The encoder,
/// writer, `frame`, `rms`, and `totalSamples` are touched ONLY on `queue`. The
/// cross-thread handoff is `carry`, a lock-guarded FIFO the audio thread appends to
/// (a memcpy, no per-callback allocation) and `queue` drains one 20 ms frame at a time.
/// `@unchecked Sendable`: the thread model above is what makes it safe; keep it.
final class OpusOggRecordingSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.klaipher.Nanogram.watchkitapp.opusEncode")
    private let encoder: OpusEncoder
    private let writer: OggOpusWriter
    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat
    private let carry = LockedSampleCarry()
    /// Audio thread only: the converter's output, grown when a larger tap buffer arrives.
    private var resampled: AVAudioPCMBuffer?
    /// Queue only: one frame's worth of samples, reused for every encode.
    private var frame = [Float](repeating: 0, count: OpusEncoder.frameSize)
    private var rms: [Float] = []
    private var totalSamples = 0

    init(outputURL: URL, inputFormat: AVAudioFormat) throws {
        encoder = try OpusEncoder()
        writer = try OggOpusWriter(url: outputURL)
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                      channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inputFormat, to: out) else {
            throw NSError(domain: "OpusOggRecordingSink", code: 1)
        }
        outFormat = out
        converter = conv
    }

    /// Audio-thread entry point. Returns the visual RMS level [0, 1] for this buffer.
    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let mono = resample(buffer), let channel = mono.floatChannelData else { return 0 }
        let samples = UnsafeBufferPointer(start: channel[0], count: Int(mono.frameLength))
        let level = AudioMeter.visualLevel(rms: AudioMeter.rms(samples))
        carry.append(samples)
        queue.async { [weak self] in self?.encodeFrames() }
        return level
    }

    /// Flushes the trailing partial frame + closes the file. Returns (duration, packed waveform).
    /// `totalSamples`/`rms` are read inside the `queue.sync` block to keep all queue-confined
    /// state confined, rather than relying on the post-sync happens-after relationship.
    func finalize() -> (duration: Int, waveform: Data) {
        return queue.sync {
            encodeFrames()
            if let remainder = carry.takePaddedRemainder(frameSize: OpusEncoder.frameSize),
               let packet = try? encoder.encode(remainder) {
                writer.writePacket(packet, samples: OpusEncoder.frameSize)
                appendRMS(remainder)
                totalSamples += OpusEncoder.frameSize
            }
            writer.finish()
            let duration = Int((Double(totalSamples) / 48_000.0).rounded())
            return (max(1, duration), WaveformPacker.pack(rms))
        }
    }

    func cancel() { queue.sync { writer.finish() } }

    // MARK: - audio thread

    /// Converts into the reused output buffer (valid until the next call) and returns it.
    private func resample(_ inBuf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outFormat.sampleRate / inBuf.format.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 256
        guard cap > 0 else { return nil }
        let outBuf: AVAudioPCMBuffer
        if let existing = resampled, existing.frameCapacity >= cap {
            outBuf = existing
        } else {
            guard let created = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return nil }
            resampled = created
            outBuf = created
        }
        var consumed = false
        var convErr: NSError?
        converter.convert(to: outBuf, error: &convErr) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        if convErr != nil { return nil }
        guard outBuf.floatChannelData != nil, outBuf.frameLength > 0 else { return nil }
        return outBuf
    }

    // MARK: - queue

    /// Encodes every complete 20 ms frame waiting in `carry`.
    private func encodeFrames() {
        while carry.popFrame(into: &frame) {
            guard let packet = try? encoder.encode(frame) else { continue }
            writer.writePacket(packet, samples: OpusEncoder.frameSize)
            appendRMS(frame)
            totalSamples += OpusEncoder.frameSize
        }
    }

    private func appendRMS(_ frame: [Float]) {
        rms.append(AudioMeter.rms(frame))
    }
}

/// Production `RecordingBackend`: AVAudioEngine mic capture → OpusOggRecordingSink.
@MainActor
final class AVRecordingBackend: RecordingBackend {
    private let engine = AVAudioEngine()
    private var sink: OpusOggRecordingSink?
    private var outputURL: URL?

    func ensurePermission() async -> RecordPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:       return .granted
        case .denied:        return .denied
        case .undetermined:
            return await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted ? .granted : .denied)
                }
            }
        @unknown default:    return .denied
        }
    }

    func begin(onLevel: @escaping @MainActor (Float) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        // Use .voiceChat mode (available watchOS 2+) and .duckOthers.
        // .allowBluetooth is deprecated on watchOS 11+; use .allowBluetoothHFP instead
        // (available watchOS 11+, target is watchOS 26). Drop if not needed at runtime.
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.duckOthers, .allowBluetoothHFP])
        try session.setActive(true)

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).ogg")
        outputURL = url
        let sink = try OpusOggRecordingSink(outputURL: url, inputFormat: inFormat)
        self.sink = sink

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat, block: Self.makeTapBlock(sink: sink, onLevel: onLevel))
        engine.prepare()
        try engine.start()
    }

    /// AVAudioEngine calls the tap on its render thread. Built outside the main actor: a
    /// closure written inside this `@MainActor` class would be main-actor isolated, and
    /// Swift 6 checks that on entry, so the first buffer would crash the app.
    nonisolated static func makeTapBlock(
        sink: OpusOggRecordingSink,
        onLevel: @escaping @MainActor (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        let throttle = LevelThrottle()
        return { buffer, _ in
            let level = sink.append(buffer)
            guard let publish = throttle.submit(level: level, now: ProcessInfo.processInfo.systemUptime) else { return }
            Task { @MainActor in onLevel(publish) }
        }
    }

    func finish() async throws -> VoiceRecordingDraft {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        guard let sink, let url = outputURL else {
            throw NSError(domain: "AVRecordingBackend", code: 1)
        }
        let (duration, waveform) = sink.finalize()
        self.sink = nil
        return VoiceRecordingDraft(fileURL: url, duration: duration, waveform: waveform)
    }

    func abort() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false)
        sink?.cancel()
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        sink = nil
        outputURL = nil
    }
}
