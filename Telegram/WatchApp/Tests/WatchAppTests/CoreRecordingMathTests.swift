import Accelerate
import AVFoundation
import OpusKit
import XCTest
@testable import tgwatch_Watch_App

/// WATCH-SIMD-1: vDSP level maths, the index-based sample carry, the level throttle, and the recording sink
/// that uses them.
final class CoreRecordingMathTests: XCTestCase {

    private func scalarRMS(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for x in s { sum += x * x }
        return (sum / Float(s.count)).squareRoot()
    }

    // MARK: AudioMeter

    func testRMSMatchesTheScalarLoop() {
        let samples = (0..<1_024).map { 0.6 * sinf(Float($0) * 0.13) }
        XCTAssertEqual(AudioMeter.rms(samples), scalarRMS(samples), accuracy: 1e-5)
    }

    func testRMSOfSilenceAndEmptyIsZero() {
        XCTAssertEqual(AudioMeter.rms([Float](repeating: 0, count: 960)), 0)
        XCTAssertEqual(AudioMeter.rms([]), 0)
    }

    func testRMSOfAConstantIsItsMagnitude() {
        XCTAssertEqual(AudioMeter.rms([Float](repeating: -0.5, count: 100)), 0.5, accuracy: 1e-6)
    }

    func testVisualLevelAppliesTheGainAndClamps() {
        XCTAssertEqual(AudioMeter.visualLevel(rms: 0.1), 0.4, accuracy: 1e-6)
        XCTAssertEqual(AudioMeter.visualLevel(rms: 0.5), 1)
        XCTAssertEqual(AudioMeter.visualLevel(rms: 0), 0)
    }

    // MARK: SampleCarry

    private func append(_ carry: inout SampleCarry, _ values: [Float]) {
        values.withUnsafeBufferPointer { carry.append($0) }
    }

    func testFramesComeOutInOrderAcrossAppends() {
        var carry = SampleCarry()
        append(&carry, (0..<500).map(Float.init))
        append(&carry, (500..<1_300).map(Float.init))
        var frame = [Float](repeating: 0, count: 960)
        XCTAssertTrue(carry.popFrame(into: &frame))
        XCTAssertEqual(frame, (0..<960).map(Float.init))
        XCTAssertEqual(carry.count, 340)
        XCTAssertFalse(carry.popFrame(into: &frame), "a partial frame is not popped")
        XCTAssertEqual(carry.count, 340)
        XCTAssertEqual(frame, (0..<960).map(Float.init), "a failed pop leaves the frame alone")
    }

    func testCompactionKeepsTheDataIntact() {
        var carry = SampleCarry()
        var next: Float = 0
        var frame = [Float](repeating: 0, count: 960)
        var expected: Float = 0
        // Long run of interleaved appends and pops that crosses the compaction threshold many times.
        for _ in 0..<200 {
            let chunk = (0..<1_000).map { _ -> Float in defer { next += 1 }; return next }
            append(&carry, chunk)
            while carry.popFrame(into: &frame) {
                XCTAssertEqual(frame[0], expected)
                XCTAssertEqual(frame[959], expected + 959)
                expected += 960
            }
        }
        XCTAssertEqual(Float(carry.count), next - expected)
    }

    func testRemainderIsPaddedToAFrame() {
        var carry = SampleCarry()
        append(&carry, [1, 2, 3])
        let remainder = carry.takePaddedRemainder(frameSize: 8)
        XCTAssertEqual(remainder, [1, 2, 3, 0, 0, 0, 0, 0])
        XCTAssertEqual(carry.count, 0)
        XCTAssertNil(carry.takePaddedRemainder(frameSize: 8))
    }

    func testRemainderAfterAPartialConsumeStartsAtTheHead() {
        var carry = SampleCarry()
        append(&carry, (0..<10).map(Float.init))
        var frame = [Float](repeating: 0, count: 4)
        XCTAssertTrue(carry.popFrame(into: &frame))
        XCTAssertEqual(carry.takePaddedRemainder(frameSize: 8), [4, 5, 6, 7, 8, 9, 0, 0])
    }

    func testLockedCarryServesAppendsFromAnotherThread() {
        let carry = LockedSampleCarry()
        let done = expectation(description: "appended")
        DispatchQueue.global().async {
            for _ in 0..<50 {
                let chunk = [Float](repeating: 1, count: 100)
                chunk.withUnsafeBufferPointer { carry.append($0) }
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        var frame = [Float](repeating: 0, count: 960)
        var frames = 0
        while carry.popFrame(into: &frame) { frames += 1 }
        XCTAssertEqual(frames, 5000 / 960)
    }

    // MARK: LevelThrottle

    func testThrottlePublishesFirstThenAtMostEveryInterval() {
        let throttle = LevelThrottle(minimumInterval: 0.05)
        XCTAssertEqual(throttle.submit(level: 0.2, now: 10.00), 0.2)
        XCTAssertNil(throttle.submit(level: 0.1, now: 10.02))
        XCTAssertNil(throttle.submit(level: 0.6, now: 10.04))
        XCTAssertEqual(throttle.submit(level: 0.3, now: 10.06), 0.6, "the loudest since the last publish")
        XCTAssertNil(throttle.submit(level: 0.1, now: 10.07))
    }

    // MARK: sink end to end

    func testSinkEncodesWhatItIsFed() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sink-\(UUID().uuidString).ogg")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try OpusOggRecordingSink(outputURL: url, inputFormat: format)
        var lastLevel: Float = 0
        for block in 0..<32 {                       // 32 * 1024 frames at 16 kHz = 2.048 s
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            buffer.frameLength = 1024
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for i in 0..<1024 { samples[i] = 0.3 * sinf(Float(block * 1024 + i) * 0.2) }
            lastLevel = sink.append(buffer)
        }
        XCTAssertGreaterThan(lastLevel, 0.1)
        let result = sink.finalize()
        XCTAssertEqual(result.duration, 2)
        XCTAssertFalse(result.waveform.isEmpty)
        let decoded = try OpusKit.OpusDecoder.decodePCM(url: url)
        let seconds = Double(decoded.pcm.frameLength) / 48_000
        XCTAssertEqual(seconds, 2.048, accuracy: 0.05)
    }

    func testSinkHandlesTapBuffersOfChangingSize() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sink-\(UUID().uuidString).ogg")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try OpusOggRecordingSink(outputURL: url, inputFormat: format)
        for size in [256, 4_096, 512, 1_024, 4_096] {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(size)))
            buffer.frameLength = AVAudioFrameCount(size)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for i in 0..<size { samples[i] = 0.2 * sinf(Float(i) * 0.1) }
            sink.append(buffer)
        }
        let result = sink.finalize()
        XCTAssertEqual(result.duration, 1)   // ~10 k frames = 0.2 s: rounds to 0, clamped to the 1 s minimum
        XCTAssertFalse(result.waveform.isEmpty)
    }
}
