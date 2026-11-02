import XCTest
import SwiftSignalKit
import RangeSet
@testable import UniversalMediaPlayer

// The direct-fetch player's lookahead thread asked MediaBox for every 64 KB read (open + stat of
// the resource file) and checked the cache for every read and seek (stat + reading the partial
// file's map from disk). In the device trace that was 38% of the lookahead threads' CPU. It now
// reads a complete file through one handle and answers "is it cached" from MediaBox's live range
// status. These tests count the MediaBox-style calls and pin that the lookahead state it reports
// is the same either way.
final class FFMpegLookaheadFileAccessTests: XCTestCase {
    private final class Counters {
        private let lock = NSLock()
        private var values: [String: Int] = [:]

        func increment(_ key: String) {
            self.lock.lock()
            self.values[key, default: 0] += 1
            self.lock.unlock()
        }

        func value(_ key: String) -> Int {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.values[key] ?? 0
        }
    }

    private struct Run {
        let finalState: FFMpegLookahead.State
        let counters: Counters
        let elapsed: Double
    }

    private func run(path: String, availableRanges: RangeSet<Int64>?, seekTo: Double = 0.0) throws -> Run {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let size = Int64(data.count)
        let counters = Counters()
        let finalState = Atomic<FFMpegLookahead.State?>(value: nil)
        let ended = self.expectation(description: "ended")
        let start = CFAbsoluteTimeGetCurrent()
        let lookahead = FFMpegLookahead(
            seekToTimestamp: seekTo,
            lookaheadDuration: 10000.0,
            updateState: { state in
                let _ = finalState.swap(state)
                if state.isEnded {
                    ended.fulfill()
                }
            },
            fetchInRange: { _ in
                counters.increment("fetch")
                return EmptyDisposable
            },
            getDataInRange: { range, completion in
                // What MediaBox.resourceData(in:) does per call: open, stat, read, close.
                counters.increment("getData")
                let lower = Int(min(Int64(data.count), range.lowerBound))
                let upper = Int(min(Int64(data.count), range.upperBound))
                completion(data.subdata(in: lower ..< upper))
                return EmptyDisposable
            },
            isDataCachedInRange: { _ in
                // MediaBox.internal_resourceDataIsCached: stat, then the partial map from disk.
                counters.increment("isCachedOnDisk")
                return true
            },
            availableRanges: Atomic(value: availableRanges),
            completedResourcePath: {
                counters.increment("completedPath")
                return path
            },
            size: size
        )
        lookahead.updateCurrentTimestamp(timestamp: seekTo)
        self.wait(for: [ended], timeout: 30.0)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        withExtendedLifetime(lookahead) {}
        return Run(finalState: try XCTUnwrap(finalState.with { $0 }), counters: counters, elapsed: elapsed)
    }

    private func fixtureSize(_ path: String) throws -> Int64 {
        return Int64(try Data(contentsOf: URL(fileURLWithPath: path)).count)
    }

    func testCompleteFileIsReadThroughOneHandle() throws {
        for (name, ext) in [("aac_h264_bframes", "mp4"), ("h264_bframes", "mp4"), ("sticker_vp9", "webm")] {
            let path = try MediaTestSupport.resourcePath(name, ext)
            let size = try self.fixtureSize(path)
            let legacy = try self.run(path: path, availableRanges: nil)
            XCTAssertGreaterThan(legacy.counters.value("getData"), 0, name)
            XCTAssertGreaterThan(legacy.counters.value("isCachedOnDisk"), 0, name)

            let complete = try self.run(path: path, availableRanges: RangeSet(0 ..< size))
            XCTAssertEqual(complete.counters.value("getData"), 0, name)
            XCTAssertEqual(complete.counters.value("isCachedOnDisk"), 0, name)
            XCTAssertEqual(complete.counters.value("completedPath"), 1, name)
            XCTAssertEqual(complete.counters.value("fetch"), 0, name)
            XCTAssertEqual(complete.finalState, legacy.finalState, name)
            print("FFMpegLookaheadFileAccessTests \(name): legacy getData \(legacy.counters.value("getData")) isCachedOnDisk \(legacy.counters.value("isCachedOnDisk")) \(String(format: "%.1f", legacy.elapsed * 1000)) ms; complete file \(String(format: "%.1f", complete.elapsed * 1000)) ms")
        }
    }

    func testPartialFileAnswersCacheChecksFromTheLiveRangeStatus() throws {
        let path = try MediaTestSupport.resourcePath("aac_h264_bframes", "mp4")
        let size = try self.fixtureSize(path)
        let legacy = try self.run(path: path, availableRanges: nil)

        // Only the first half: the second half is fetched; the cache is still never checked on disk.
        let half = try self.run(path: path, availableRanges: RangeSet(0 ..< size / 2))
        XCTAssertEqual(half.counters.value("isCachedOnDisk"), 0)
        XCTAssertEqual(half.counters.value("completedPath"), 0)
        XCTAssertGreaterThan(half.counters.value("getData"), 0)
        XCTAssertGreaterThan(half.counters.value("fetch"), 0)
        XCTAssertEqual(half.finalState, legacy.finalState)
    }

    func testSeekedLookaheadMatchesTheLegacyPath() throws {
        let path = try MediaTestSupport.resourcePath("aac_h264_bframes", "mp4")
        let size = try self.fixtureSize(path)
        let legacy = try self.run(path: path, availableRanges: nil, seekTo: 1.0)
        let complete = try self.run(path: path, availableRanges: RangeSet(0 ..< size), seekTo: 1.0)
        XCTAssertEqual(complete.finalState, legacy.finalState)
        XCTAssertEqual(complete.counters.value("getData"), 0)
    }
}
