import AVFoundation
import COgg
import COpus

/// Decodes an Ogg Opus file a chunk at a time (WATCH-MEM-1).
///
/// `OpusDecoder.decodePCM` decodes the whole note, one sample at a time, into an array and then copies that into
/// a second full-length buffer: a 5-minute note peaked near 115 MB and nothing played until the last packet was
/// decoded. This decoder pulls pages from the memory-mapped file on demand, decodes each packet straight into the
/// destination `AVAudioPCMBuffer` (`opus_decode_float`, no intermediate array for mono) and applies the pre-skip
/// by trimming the first packets, so the caller can schedule successive buffers and start playing after the first.
///
/// Not thread-safe: use one instance from one task at a time (the controller drives it from a single decode task).
/// `@unchecked Sendable` only so that task can own it.
public final class OpusChunkedDecoder: @unchecked Sendable {
    public static let sampleRate = 48_000
    /// The largest packet Opus produces: 120 ms at 48 kHz.
    static let maxFramesPerPacket = 5_760
    private static let feedSize = 16 * 1024

    public let channelCount: Int
    /// Decoded length in seconds from the last Ogg page's granule position minus the pre-skip; nil when the file
    /// carries no usable granule position.
    public let totalDuration: Double?

    private let data: Data
    private var offset = 0
    private let sync: UnsafeMutablePointer<ogg_sync_state>
    private let stream: UnsafeMutablePointer<ogg_stream_state>
    private let page: UnsafeMutablePointer<ogg_page>
    private let packet: UnsafeMutablePointer<ogg_packet>
    private var streamInitialized = false
    private var decoder: OpaquePointer?
    private var skipRemaining: Int
    private let scratch: UnsafeMutablePointer<Float>
    private let format: AVAudioFormat
    private var finished = false

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw OpusDecoderError.fileNotFound }
        let mapped: Data
        do {
            mapped = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw OpusDecoderError.fileNotFound
        }
        guard mapped.count >= 4, mapped[0] == 0x4F, mapped[1] == 0x67, mapped[2] == 0x67, mapped[3] == 0x53 else {
            throw OpusDecoderError.notOggOpus
        }
        let header = try Self.scan(mapped)
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: AVAudioChannelCount(header.channels),
            interleaved: false
        ) else {
            throw OpusDecoderError.decode("AVAudioFormat failed")
        }

        data = mapped
        format = pcmFormat
        channelCount = header.channels
        skipRemaining = header.preSkip
        if let last = header.lastGranule, last > Int64(header.preSkip) {
            totalDuration = Double(last - Int64(header.preSkip)) / Double(Self.sampleRate)
        } else {
            totalDuration = nil
        }
        sync = UnsafeMutablePointer<ogg_sync_state>.allocate(capacity: 1)
        sync.initialize(to: ogg_sync_state())
        ogg_sync_init(sync)
        stream = UnsafeMutablePointer<ogg_stream_state>.allocate(capacity: 1)
        stream.initialize(to: ogg_stream_state())
        page = UnsafeMutablePointer<ogg_page>.allocate(capacity: 1)
        page.initialize(to: ogg_page())
        packet = UnsafeMutablePointer<ogg_packet>.allocate(capacity: 1)
        packet.initialize(to: ogg_packet())
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFramesPerPacket * 2)
        scratch.initialize(repeating: 0, count: Self.maxFramesPerPacket * 2)

        // From here on a throw runs `deinit`, which frees the allocations above.
        var err: Int32 = 0
        let created = opus_decoder_create(Int32(Self.sampleRate), Int32(header.channels), &err)
        guard err == OPUS_OK, let created else {
            throw OpusDecoderError.decode("opus_decoder_create err=\(err)")
        }
        decoder = created
        // OpusHead and OpusTags.
        guard try nextPacket(), try nextPacket() else { throw OpusDecoderError.notOggOpus }
    }

    deinit {
        if let decoder { opus_decoder_destroy(decoder) }
        if streamInitialized { ogg_stream_clear(stream) }
        ogg_sync_clear(sync)
        sync.deallocate()
        stream.deallocate()
        page.deallocate()
        packet.deallocate()
        scratch.deallocate()
    }

    /// Decodes up to roughly `maxFrames` frames (it finishes the packet it is in, so a chunk is at most
    /// `maxFrames + 5_759`) into a new buffer. Returns nil once the stream is exhausted.
    public func nextChunk(maxFrames: Int = 24_000) throws -> AVAudioPCMBuffer? {
        guard !finished, let decoder else { return nil }
        let target = max(1, maxFrames)
        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(target + Self.maxFramesPerPacket)
        ), let channels = pcm.floatChannelData else {
            throw OpusDecoderError.decode("AVAudioPCMBuffer alloc failed")
        }
        var filled = 0
        while filled < target {
            guard try nextPacket() else {
                finished = true
                break
            }
            guard let bytes = packet.pointee.packet else { throw OpusDecoderError.notOggOpus }
            let length = Int32(packet.pointee.bytes)
            let left = channels[0] + filled
            let decoded: Int32
            if channelCount == 1 {
                decoded = opus_decode_float(decoder, bytes, length, left, Int32(Self.maxFramesPerPacket), 0)
            } else {
                decoded = opus_decode_float(decoder, bytes, length, scratch, Int32(Self.maxFramesPerPacket), 0)
            }
            if decoded < 0 { throw OpusDecoderError.decode("opus_decode_float err=\(decoded)") }

            let frames = Int(decoded)
            let drop = min(skipRemaining, frames)
            skipRemaining -= drop
            let produced = frames - drop
            guard produced > 0 else { continue }
            if channelCount == 1 {
                if drop > 0 { memmove(left, left + drop, produced * MemoryLayout<Float>.size) }
            } else {
                let right = channels[1] + filled
                for f in 0..<produced {
                    left[f] = scratch[(drop + f) * 2]
                    right[f] = scratch[(drop + f) * 2 + 1]
                }
            }
            filled += produced
        }
        guard filled > 0 else { return nil }
        pcm.frameLength = AVAudioFrameCount(filled)
        return pcm
    }

    // MARK: - Ogg plumbing

    /// Next audio-or-header packet into `packet`; false at the end of the file. Pages that fail to sync are
    /// skipped (libogg convention) rather than treated as the end.
    private func nextPacket() throws -> Bool {
        while true {
            let result = ogg_stream_packetout(stream, packet)
            if result == 1 { return true }
            if result < 0 { continue }
            let pageResult = ogg_sync_pageout(sync, page)
            if pageResult == 1 {
                if !streamInitialized {
                    ogg_stream_init(stream, ogg_page_serialno(page))
                    streamInitialized = true
                }
                ogg_stream_pagein(stream, page)
                continue
            }
            if pageResult < 0 { continue }
            if offset >= data.count { return false }
            try feed()
        }
    }

    private func feed() throws {
        let count = min(Self.feedSize, data.count - offset)
        guard let destination = ogg_sync_buffer(sync, count) else {
            throw OpusDecoderError.decode("ogg_sync_buffer failed")
        }
        let start = offset
        let copied = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            memcpy(destination, base + start, count)
            return true
        }
        guard copied else { throw OpusDecoderError.decode("no data") }
        ogg_sync_wrote(sync, count)
        offset += count
    }

    private struct Header {
        let channels: Int
        let preSkip: Int
        let lastGranule: Int64?
    }

    /// One pass over the page headers: channel count and pre-skip from OpusHead, and the last granule position
    /// (the decoded length). It copies 16 KB at a time and decodes nothing.
    private static func scan(_ data: Data) throws -> Header {
        var sync = ogg_sync_state()
        ogg_sync_init(&sync)
        defer { ogg_sync_clear(&sync) }
        var page = ogg_page()
        var channels = 0
        var preSkip = 0
        var lastGranule: Int64?
        var haveHead = false
        var offset = 0
        while true {
            let result = ogg_sync_pageout(&sync, &page)
            if result == 1 {
                if !haveHead {
                    var st = ogg_stream_state()
                    ogg_stream_init(&st, ogg_page_serialno(&page))
                    ogg_stream_pagein(&st, &page)
                    var pkt = ogg_packet()
                    let got = ogg_stream_packetout(&st, &pkt)
                    ogg_stream_clear(&st)
                    guard got == 1, let base = pkt.packet, pkt.bytes >= 19 else { throw OpusDecoderError.notOggOpus }
                    let head = UnsafeBufferPointer(start: base, count: Int(pkt.bytes))
                    guard head[0] == 0x4F, head[1] == 0x70, head[2] == 0x75, head[3] == 0x73,
                          head[4] == 0x48, head[5] == 0x65, head[6] == 0x61, head[7] == 0x64 else {
                        throw OpusDecoderError.notOggOpus
                    }
                    channels = Int(head[9])
                    preSkip = Int(head[10]) | (Int(head[11]) << 8)
                    // The plain decoder is mono or stereo only (no multistream), like `OpusDecoder`.
                    guard channels == 1 || channels == 2 else { throw OpusDecoderError.notOggOpus }
                    haveHead = true
                }
                let granule = ogg_page_granulepos(&page)
                if granule >= 0 { lastGranule = Int64(granule) }
                continue
            }
            if result < 0 { continue }
            if offset >= data.count { break }
            let count = min(feedSize, data.count - offset)
            guard let destination = ogg_sync_buffer(&sync, count) else {
                throw OpusDecoderError.decode("ogg_sync_buffer failed")
            }
            let start = offset
            let copied = data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                memcpy(destination, base + start, count)
                return true
            }
            guard copied else { throw OpusDecoderError.decode("no data") }
            ogg_sync_wrote(&sync, count)
            offset += count
        }
        guard haveHead else { throw OpusDecoderError.notOggOpus }
        return Header(channels: channels, preSkip: preSkip, lastGranule: lastGranule)
    }
}
