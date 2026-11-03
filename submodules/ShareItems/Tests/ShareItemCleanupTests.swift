import XCTest
import Foundation
import UniformTypeIdentifiers
import MtProtoKit
import SwiftSignalKit
import ShareItemsImpl
import ShareItems

// I-11 review fixes: a share's copies never outlive it (the sweep, copies finishing after the share
// ended), and the work for each item, a voice waveform included, waits for its turn and stays
// within a fixed amount of memory.

private func makeDirectory(_ name: String) -> String {
    let path = NSTemporaryDirectory() + "\(name)-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func setModificationDate(_ path: String, secondsAgo: TimeInterval) {
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-secondsAgo)], ofItemAtPath: path)
}

private func modificationDate(_ path: String) -> Date? {
    return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

private func contents(_ path: String) -> [String] {
    return (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
}

/// Runs the main run loop until `condition` holds or `timeout` passes.
private func spin(until condition: () -> Bool, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

final class ShareItemFilesSweepTests: XCTestCase {
    private var parent: String!

    override func setUp() {
        super.setUp()
        self.parent = makeDirectory("ShareItemFilesSweep")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.parent)
        super.tearDown()
    }

    private func makeAttempt(_ name: String, secondsAgo: TimeInterval) -> String {
        let path = self.parent + "/" + name
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/copy.bin", contents: Data("x".utf8))
        setModificationDate(path, secondsAgo: secondsAgo)
        return path
    }

    private func sweep() -> Bool {
        let done = expectation(description: "swept")
        var removedOnMainThread = true
        removeStaleShareItemFiles(parentPath: self.parent, completion: {
            removedOnMainThread = Thread.isMainThread
            done.fulfill()
        })
        wait(for: [done], timeout: 10.0)
        return removedOnMainThread
    }

    // The sweep can delete gigabytes: it must not run on the thread that asks for it (the main
    // thread, at launch or on Send).
    func testSweepRunsOffTheCallingThread() {
        XCTAssertTrue(Thread.isMainThread)
        let _ = makeAttempt("old", secondsAgo: 2.0 * 24.0 * 60.0 * 60.0)
        XCTAssertFalse(sweep(), "the sweep ran on the main thread")
        XCTAssertEqual(contents(self.parent), [])
    }

    // An attempt never outlives its extension, and a running one is kept fresh (below), so what a
    // killed extension left goes after an hour, not a day.
    func testAttemptsLeftByAKilledExtensionGoAfterAnHour() {
        let _ = makeAttempt("killed", secondsAgo: 2.0 * 60.0 * 60.0)
        let _ = makeAttempt("recent", secondsAgo: 10.0 * 60.0)
        let _ = sweep()
        XCTAssertEqual(contents(self.parent), ["recent"])
    }

    // A long upload in a running extension is not swept by the app (or by another extension): the
    // attempt's directory is touched while its share makes progress.
    func testARunningAttemptIsKeptFreshAndNotSwept() {
        let pipe = ValuePipe<Int>()
        var attempt: String?
        let disposable = withShareItemFiles(parentPath: self.parent, touchInterval: 0.0) { directory -> Signal<Int, NoError> in
            attempt = directory
            return pipe.signal()
        }.start()
        defer {
            disposable.dispose()
        }
        guard let attempt else {
            XCTFail("no attempt directory")
            return
        }
        setModificationDate(attempt, secondsAgo: 2.0 * 24.0 * 60.0 * 60.0)
        pipe.putNext(1)
        spin(until: { (modificationDate(attempt).map { -$0.timeIntervalSinceNow } ?? .infinity) < 60.0 }, timeout: 5.0)
        let _ = sweep()
        XCTAssertTrue(FileManager.default.fileExists(atPath: attempt), "a running attempt was swept")
    }
}

/// A provider whose data arrives only when `release` is signalled.
private final class HeldProvider {
    let provider = NSItemProvider()
    let asked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    init(url: URL, typeIdentifier: String) {
        self.provider.suggestedName = url.lastPathComponent
        self.provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { [asked, release] completion in
            asked.signal()
            DispatchQueue.global().async {
                release.wait()
                completion(try? Data(contentsOf: url, options: .alwaysMapped), nil)
            }
            return nil
        }
    }
}

/// A provider that cannot give its attachment as a file and hands out a file URL item instead (as
/// older apps share audio and movies), only when `release` is signalled.
private final class HeldURLProvider {
    let provider = NSItemProvider()
    let asked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    init(url: URL, typeIdentifier: String) {
        let requests = Atomic<Int>(value: 0)
        self.provider.registerItem(forTypeIdentifier: typeIdentifier) { [asked, release] completion, _, _ in
            // The first request is for the file representation: refused, so the URL item is asked for.
            if requests.modify({ $0 + 1 }) == 1 {
                completion?(nil, NSError(domain: "HeldURLProvider", code: 1))
                return
            }
            asked.signal()
            DispatchQueue.global().async {
                release.wait()
                completion?(url as NSURL, nil)
            }
        }
    }
}

final class ShareItemCopyAfterEndTests: XCTestCase {
    private var source: String!
    private var parent: String!

    override func setUp() {
        super.setUp()
        self.source = makeDirectory("ShareItemCopySource")
        self.parent = makeDirectory("ShareItemCopyParent")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.source)
        try? FileManager.default.removeItem(atPath: self.parent)
        super.tearDown()
    }

    private func writeSource(_ name: String) -> URL {
        let url = URL(fileURLWithPath: self.source + "/" + name)
        try! Data(repeating: 7, count: 64 * 1024).write(to: url)
        return url
    }

    // The attempt's directory is gone once its share ends: a copy made after that must fail rather
    // than create the directory again with a full-size copy nobody removes.
    func testCopyIntoAnEndedShareFailsAndLeavesNothing() {
        let file = writeSource("Report.pdf")
        let ended = self.parent + "/" + UUID().uuidString
        XCTAssertNil(TGItemProviderSignals.copyFile(at: file, toTemporaryDirectory: ended))
        XCTAssertEqual(contents(self.parent), [], "the ended share's directory was created again")
    }

    func testCopyIntoARunningShareSucceeds() {
        let file = writeSource("Report.pdf")
        let attempt = self.parent + "/attempt"
        try! FileManager.default.createDirectory(atPath: attempt, withIntermediateDirectories: false)
        let copy = TGItemProviderSignals.copyFile(at: file, toTemporaryDirectory: attempt)
        XCTAssertEqual(copy?.lastPathComponent, "Report.pdf")
        XCTAssertTrue(copy.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }

    // The system delivers the attachment after the share was cancelled (it was still fetching it):
    // no copy is left behind.
    func testAttachmentArrivingAfterCancelLeavesNoCopy() {
        let held = HeldProvider(url: writeSource("Report.pdf"), typeIdentifier: UTType.data.identifier)
        let item = NSExtensionItem()
        item.attachments = [held.provider]
        let disposable = withShareItemFiles(parentPath: self.parent) { directory -> Signal<[[String: Any]], PreparedShareItemError> in
            return shareItemDictionaries(dataItems: TGItemProviderSignals.itemSignals(forInputItems: [item], highQuality: false, temporaryDirectory: directory))
        }.start()
        // Not blocking: providers are asked on the main queue.
        var asked = false
        spin(until: {
            asked = asked || held.asked.wait(timeout: .now()) == .success
            return asked
        }, timeout: 10.0)
        XCTAssertTrue(asked, "the provider was never asked")
        disposable.dispose()
        spin(until: { contents(self.parent).isEmpty }, timeout: 5.0)
        XCTAssertEqual(contents(self.parent), [])
        held.release.signal()
        // Long enough for the late delivery and its copy.
        spin(until: { !contents(self.parent).isEmpty }, timeout: 2.0)
        XCTAssertEqual(contents(self.parent), [], "a copy made after the share was cancelled was left behind")
    }

    // The same for a file URL item, whose load cannot be cancelled at all.
    func testFileURLArrivingAfterCancelLeavesNoCopy() {
        let source = self.source + "/memo.wav"
        try! Data(repeating: 1, count: 64 * 1024).write(to: URL(fileURLWithPath: source))
        let held = HeldURLProvider(url: URL(fileURLWithPath: source), typeIdentifier: UTType.audio.identifier)
        let item = NSExtensionItem()
        item.attachments = [held.provider]
        let disposable = withShareItemFiles(parentPath: self.parent) { directory -> Signal<[[String: Any]], PreparedShareItemError> in
            return shareItemDictionaries(dataItems: TGItemProviderSignals.itemSignals(forInputItems: [item], highQuality: false, temporaryDirectory: directory))
        }.start()
        // Not blocking: providers are asked on the main queue.
        var asked = false
        spin(until: {
            asked = asked || held.asked.wait(timeout: .now()) == .success
            return asked
        }, timeout: 10.0)
        XCTAssertTrue(asked, "the provider was never asked")
        disposable.dispose()
        spin(until: { contents(self.parent).isEmpty }, timeout: 5.0)
        XCTAssertEqual(contents(self.parent), [])
        held.release.signal()
        spin(until: { !contents(self.parent).isEmpty }, timeout: 2.0)
        XCTAssertEqual(contents(self.parent), [], "a copy made after the share was cancelled was left behind")
    }
}

/// 16-bit mono PCM in a WAV container.
private func writeVoiceWav(path: String, seconds: Double) {
    let sampleRate: UInt32 = 8000
    let sampleCount = UInt32(Double(sampleRate) * seconds)
    let dataSize = sampleCount * 2
    var data = Data()
    func append<T>(_ value: T) {
        var value = value
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + dataSize).littleEndian)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16).littleEndian)
    append(UInt16(1).littleEndian)
    append(UInt16(1).littleEndian)
    append(sampleRate.littleEndian)
    append((sampleRate * 2).littleEndian)
    append(UInt16(2).littleEndian)
    append(UInt16(16).littleEndian)
    data.append(contentsOf: Array("data".utf8))
    append(dataSize.littleEndian)
    for i in 0 ..< Int(sampleCount) {
        append(Int16(sin(Double(i) * 0.3) * 8000.0 * (0.2 + 0.8 * Double(i % 4000) / 4000.0)).littleEndian)
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

final class ShareItemAudioWaveformTests: XCTestCase {
    // Only a voice message shows a waveform: other audio (music, an audiobook) is not decoded for
    // one, which took a full decode before its upload could start.
    func testWaveformIsOnlyMadeForVoiceMessages() {
        let directory = makeDirectory("ShareItemWaveform")
        defer {
            try? FileManager.default.removeItem(atPath: directory)
        }
        let path = directory + "/memo.wav"
        writeVoiceWav(path: path, seconds: 3.0)
        XCTAssertNil(shareAudioWaveform(url: URL(fileURLWithPath: path), isVoice: false))
        XCTAssertEqual(shareAudioWaveform(url: URL(fileURLWithPath: path), isVoice: true)?.count, 63)
    }

    // Twenty minutes of 44.1 kHz stereo: the peaks kept stay within a fixed size (they grew by one
    // for every 100 samples, ~6 MB for an hour of stereo, ~63 MB for ten).
    func testPeaksStayWithinAFixedSizeForLongAudio() {
        let peaks = TGAudioWaveformPeaks()
        var chunk = [Int16](repeating: 0, count: 1 << 20)
        for i in 0 ..< chunk.count {
            chunk[i] = Int16(truncatingIfNeeded: (i &* 7919) % 30000)
        }
        let total = 44100 * 2 * 20 * 60
        var added = 0
        while added < total {
            let count = min(chunk.count, total - added)
            chunk.withUnsafeBufferPointer { buffer in
                peaks.addSamples(buffer.baseAddress!, count: UInt(count))
            }
            added += count
        }
        XCTAssertLessThanOrEqual(peaks.storedPeakCount, TGAudioWaveformPeaks.capacity())
        XCTAssertEqual(peaks.waveform().count, 63)
    }

    // Merging peaks does not change the waveform: here every hundredth of the audio is 64 peaks of
    // 100 samples, merged into 32 pairs, and each value is still the largest peak of its hundredth.
    func testMergedPeaksGiveTheSameWaveformAsKeepingEveryPeak() {
        let rawPeakCount = 6400
        var samples = [Int16](repeating: 0, count: rawPeakCount * 100)
        var state: UInt32 = 12345
        for i in 0 ..< samples.count {
            state = state &* 1103515245 &+ 12345
            let magnitude = Int16((state >> 8) % 32000)
            samples[i] = (state & 1) == 0 ? magnitude : -magnitude
        }
        var expected = [Int16](repeating: 0, count: 100)
        for peakIndex in 0 ..< rawPeakCount {
            var peak: Int16 = 0
            for sample in samples[(peakIndex * 100) ..< (peakIndex * 100 + 100)] {
                peak = max(peak, abs(sample))
            }
            let bucket = peakIndex * 100 / rawPeakCount
            expected[bucket] = max(expected[bucket], peak)
        }

        let peaks = TGAudioWaveformPeaks()
        samples.withUnsafeBufferPointer { buffer in
            // In uneven pieces, as sample buffers arrive.
            var offset = 0
            var piece = 1
            while offset < buffer.count {
                let count = min(piece * 977, buffer.count - offset)
                peaks.addSamples(buffer.baseAddress! + offset, count: UInt(count))
                offset += count
                piece += 1
            }
        }
        let scaled = peaks.scaledPeaks().withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(scaled, expected)
    }
}

final class PreparedShareItemSignalsTests: XCTestCase {
    // An item's preparation (a waveform decode, a photo downsample, a PDF preview) starts when the
    // concurrency limit lets it, not for every item at once when the share starts.
    func testItemsArePreparedOnlyWhenTheirTurnComes() {
        let prepared = Atomic<Int>(value: 0)
        let items: [[String: Any]] = (0 ..< 5).map { ["index": $0] }
        let signals = preparedShareItemSignals(items, prepare: { _ -> Signal<Int, NoError> in
            let _ = prepared.modify { $0 + 1 }
            return .never()
        })
        XCTAssertEqual(prepared.with { $0 }, 0, "items were prepared before the share started")
        let disposable = combineLatestLimitingConcurrency(signals, pendingValue: 0, maxConcurrent: maxConcurrentPreparedShareItems).start()
        spin(until: { prepared.with { $0 } >= maxConcurrentPreparedShareItems }, timeout: 5.0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(prepared.with { $0 }, maxConcurrentPreparedShareItems)
        disposable.dispose()
    }
}
