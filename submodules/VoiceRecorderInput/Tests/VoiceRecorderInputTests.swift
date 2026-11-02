import Foundation
import XCTest
import OpusBinding
import VoiceRecorderInput

// The voice recorder's input path moved off Swift on the real-time thread: the IO callback now
// appends samples to a lock-free ring and the recorder queue takes 20 ms encoder packets from it.
// These tests feed a synthetic producer through the ring and through the previous packetizer
// (ManagedAudioRecorderContext.processAndDisposeAudioBuffer before the change) and require the
// same Opus output.
final class VoiceRecorderInputTests: XCTestCase {
    // 48 kHz, 16-bit mono, 20 ms per encoder packet: what the recorder hands TGOggOpusWriter.
    private let packetSize = 16000 / 1000 * 60 * 2

    private func syntheticPCM(seconds: Double) -> Data {
        let sampleCount = Int(48000.0 * seconds)
        var samples = [Int16](repeating: 0, count: sampleCount)
        var noise: UInt32 = 12345
        for i in 0 ..< sampleCount {
            noise = noise &* 1103515245 &+ 12345
            let t = Double(i) / 48000.0
            let tone = sin(2.0 * Double.pi * 220.0 * t) * 6000.0 + sin(2.0 * Double.pi * 1375.0 * t) * 2000.0
            let jitter = Double(Int32(bitPattern: noise) >> 20)
            samples[i] = Int16(clamping: Int(tone + jitter))
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    // IO cycle sizes in frames, as RemoteIO may deliver them (including odd and tiny ones).
    private func chunks(_ pcm: Data) -> [Data] {
        let frameCounts = [1024, 940, 1156, 470, 4096, 1, 2, 960, 1023, 333]
        var result: [Data] = []
        var offset = 0
        var index = 0
        while offset < pcm.count {
            let length = min(pcm.count - offset, frameCounts[index % frameCounts.count] * 2)
            result.append(pcm.subdata(in: offset ..< offset + length))
            offset += length
            index += 1
        }
        return result
    }

    // The packetizer the recorder used before: whole packets go to the encoder, the rest waits in
    // `audioBuffer` for the next IO buffer.
    private final class PreviousPacketizer {
        private var audioBuffer = Data()
        private let packetSize: Int

        init(packetSize: Int) {
            self.packetSize = packetSize
        }

        func process(_ buffer: Data, emit: (Data) -> Void) {
            var bufferOffset = 0
            var packet = Data(count: self.packetSize)
            while true {
                var packetFill = 0
                while packetFill < self.packetSize {
                    if self.audioBuffer.count != 0 {
                        let taken = min(self.audioBuffer.count, self.packetSize - packetFill)
                        packet.replaceSubrange(packetFill ..< packetFill + taken, with: self.audioBuffer.prefix(taken))
                        self.audioBuffer.replaceSubrange(0 ..< taken, with: Data())
                        packetFill += taken
                    } else if bufferOffset < buffer.count {
                        let taken = min(buffer.count - bufferOffset, self.packetSize - packetFill)
                        packet.replaceSubrange(packetFill ..< packetFill + taken, with: buffer.subdata(in: bufferOffset ..< bufferOffset + taken))
                        bufferOffset += taken
                        packetFill += taken
                    } else {
                        break
                    }
                }
                if packetFill < self.packetSize {
                    self.audioBuffer.append(packet.prefix(packetFill))
                    break
                } else {
                    emit(packet)
                }
            }
        }
    }

    private final class Encoder {
        let writer = TGOggOpusWriter()
        let item = TGDataItem()
        var packets: [Data] = []

        init() {
            XCTAssertTrue(self.writer.begin(with: self.item))
        }

        func add(_ packet: Data) {
            self.packets.append(packet)
            var bytes = packet
            bytes.withUnsafeMutableBytes { buffer in
                _ = self.writer.writeFrame(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(buffer.count))
            }
        }

        func finish() -> Data {
            _ = self.writer.writeFrame(nil, frameByteCount: 0)
            return self.item.data()
        }
    }

    // The Ogg stream serial number is random per writer; it and the page checksums that cover it
    // are zeroed so two encodings of the same packets compare byte for byte.
    private func normalizedOgg(_ data: Data) -> Data {
        var result = data
        var offset = 0
        let pattern = Data("OggS".utf8)
        while offset + 27 <= result.count {
            guard result.subdata(in: offset ..< offset + 4) == pattern else {
                offset += 1
                continue
            }
            for i in 14 ..< 18 {
                result[offset + i] = 0
            }
            for i in 22 ..< 26 {
                result[offset + i] = 0
            }
            let segmentCount = Int(result[offset + 26])
            var pageLength = 27 + segmentCount
            for i in 0 ..< segmentCount {
                pageLength += Int(result[offset + 27 + i])
            }
            offset += pageLength
        }
        return result
    }

    private func previousOutput(_ chunks: [Data]) -> (packets: [Data], ogg: Data) {
        let encoder = Encoder()
        let packetizer = PreviousPacketizer(packetSize: self.packetSize)
        for chunk in chunks {
            packetizer.process(chunk, emit: encoder.add)
        }
        return (encoder.packets, encoder.finish())
    }

    private func drain(_ input: OpaquePointer, into encoder: Encoder) {
        var packet = Data(count: self.packetSize)
        while packet.withUnsafeMutableBytes({ VoiceRecorderInputReadExactly(input, $0.baseAddress!, UInt32($0.count)) }) {
            encoder.add(packet)
        }
    }

    private func write(_ input: OpaquePointer, _ chunk: Data) -> Bool {
        return chunk.withUnsafeBytes { VoiceRecorderInputWrite(input, $0.baseAddress!, UInt32($0.count)) }
    }

    private func assertSameEncoding(_ actual: (packets: [Data], ogg: Data), _ expected: (packets: [Data], ogg: Data), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.packets.count, expected.packets.count, file: file, line: line)
        XCTAssertTrue(actual.packets == expected.packets, "encoder input differs", file: file, line: line)
        let actualFrames = OggOpusReader.extractFrames(actual.ogg)?.map(\.data) ?? []
        let expectedFrames = OggOpusReader.extractFrames(expected.ogg)?.map(\.data) ?? []
        XCTAssertGreaterThan(expectedFrames.count, 100, file: file, line: line)
        XCTAssertTrue(actualFrames == expectedFrames, "Opus packets differ", file: file, line: line)
        XCTAssertEqual(actual.ogg.count, expected.ogg.count, file: file, line: line)
        XCTAssertTrue(self.normalizedOgg(actual.ogg) == self.normalizedOgg(expected.ogg), "Ogg files differ", file: file, line: line)
    }

    func testRingGivesTheSameOpusOutputAsThePreviousPacketizer() throws {
        let chunks = self.chunks(self.syntheticPCM(seconds: 3.0))
        let expected = self.previousOutput(chunks)
        // Drained after every IO cycle, and on a timer that sees several cycles at once.
        for drainEvery in [1, 3, 7] {
            let input = try XCTUnwrap(VoiceRecorderInputCreate(192_000, 8192))
            defer {
                VoiceRecorderInputDestroy(input)
            }
            let encoder = Encoder()
            for (index, chunk) in chunks.enumerated() {
                XCTAssertTrue(self.write(input, chunk))
                if (index + 1) % drainEvery == 0 {
                    self.drain(input, into: encoder)
                }
            }
            self.drain(input, into: encoder)
            // Less than one packet stays buffered for the next segment, as `audioBuffer` did.
            XCTAssertLessThan(VoiceRecorderInputAvailableBytes(input), UInt32(self.packetSize))
            self.assertSameEncoding((encoder.packets, encoder.finish()), expected)
            XCTAssertEqual(VoiceRecorderInputDroppedBytes(input), 0)
        }
    }

    // A producer thread and a draining consumer at the same time, as on the IO thread.
    func testConcurrentProducerKeepsEveryByteInOrder() throws {
        let chunks = self.chunks(self.syntheticPCM(seconds: 3.0))
        let expected = self.previousOutput(chunks)
        let input = try XCTUnwrap(VoiceRecorderInputCreate(16_384, 8192))
        defer {
            VoiceRecorderInputDestroy(input)
        }
        let encoder = Encoder()
        let done = DispatchSemaphore(value: 0)
        let producerFinished = ManagedAtomicFlag()
        let thread = Thread {
            for chunk in chunks {
                // The ring is small here; wait for room instead of dropping, to compare outputs.
                while !self.write(input, chunk) {
                    usleep(50)
                }
            }
            producerFinished.set()
            done.signal()
        }
        thread.start()
        while !producerFinished.value {
            self.drain(input, into: encoder)
            usleep(200)
        }
        XCTAssertEqual(done.wait(timeout: .now() + 30.0), .success)
        self.drain(input, into: encoder)
        self.assertSameEncoding((encoder.packets, encoder.finish()), expected)
    }

    func testFullRingDropsWholeWritesAndCountsThem() throws {
        let input = try XCTUnwrap(VoiceRecorderInputCreate(4096, 8192))
        defer {
            VoiceRecorderInputDestroy(input)
        }
        let chunk = Data(repeating: 7, count: 1500)
        XCTAssertTrue(self.write(input, chunk))
        XCTAssertTrue(self.write(input, chunk))
        XCTAssertFalse(self.write(input, chunk))
        XCTAssertEqual(VoiceRecorderInputAvailableBytes(input), 3000)
        XCTAssertEqual(VoiceRecorderInputDroppedBytes(input), 1500)
        VoiceRecorderInputDiscardAll(input)
        XCTAssertEqual(VoiceRecorderInputAvailableBytes(input), 0)
        XCTAssertTrue(self.write(input, chunk))
        var out = Data(count: 1500)
        XCTAssertTrue(out.withUnsafeMutableBytes { VoiceRecorderInputReadExactly(input, $0.baseAddress!, 1500) })
        XCTAssertEqual(out, chunk)
    }

    // With no audio unit set the callback renders nothing and still reports success to Core Audio.
    func testCallbackWithoutAudioUnitDoesNothing() throws {
        let input = try XCTUnwrap(VoiceRecorderInputCreate(4096, 1024))
        defer {
            VoiceRecorderInputDestroy(input)
        }
        var flags = AudioUnitRenderActionFlags()
        var timeStamp = AudioTimeStamp()
        XCTAssertEqual(VoiceRecorderInputRenderCallback(UnsafeMutableRawPointer(input), &flags, &timeStamp, 1, 512, nil), noErr)
        XCTAssertEqual(VoiceRecorderInputAvailableBytes(input), 0)
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.flag
    }

    func set() {
        self.lock.lock()
        self.flag = true
        self.lock.unlock()
    }
}
