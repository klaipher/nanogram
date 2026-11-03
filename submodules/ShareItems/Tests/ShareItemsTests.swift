import XCTest
import UIKit
import MtProtoKit
import SwiftSignalKit
import ShareItemsImpl
import ShareItems

final class ShareItemDictionariesTests: XCTestCase {
    private func outcome(_ dataItems: [MTSignal], timeout: Double = 2.0) -> (count: Int?, failed: Bool) {
        let done = expectation(description: "finished")
        var count: Int?
        var failed = false
        let disposable = shareItemDictionaries(dataItems: dataItems).start(next: { items in
            count = items.count
        }, error: { error in
            if case .generic = error {
                failed = true
            }
            done.fulfill()
        }, completed: {
            done.fulfill()
        })
        wait(for: [done], timeout: timeout)
        disposable.dispose()
        return (count, failed)
    }

    // I-2: a provider that fails (an unreadable file, a movie with no video track) used to leave
    // the sheet preparing forever; it now fails the share.
    func testFailingProviderFailsTheShare() {
        let result = outcome([MTSignal.single(["text": "a"]), MTSignal.fail(nil)])
        XCTAssertTrue(result.failed)
    }

    func testProviderThatCompletesWithoutAnItemFailsTheShare() {
        let result = outcome([MTSignal.complete()])
        XCTAssertTrue(result.failed)
    }

    func testProviderWithAnUnexpectedValueFailsTheShare() {
        let result = outcome([MTSignal.single(NSNumber(value: 1))])
        XCTAssertTrue(result.failed)
    }

    func testItemsAreCollectedInOrder() {
        let done = expectation(description: "finished")
        var texts: [String] = []
        let _ = shareItemDictionaries(dataItems: [MTSignal.single(["text": "a"]), MTSignal.single(["text": "b"])]).start(next: { items in
            texts = items.compactMap { $0["text"] as? String }
        }, completed: {
            done.fulfill()
        })
        wait(for: [done], timeout: 2.0)
        XCTAssertEqual(texts, ["a", "b"])
    }
}

final class CombineLatestLimitingConcurrencyTests: XCTestCase {
    // I-10: at most `maxConcurrent` items are prepared and uploaded at once.
    func testRunsAtMostMaxConcurrentAtOnce() {
        let running = Atomic<Int>(value: 0)
        let maxRunning = Atomic<Int>(value: 0)
        let signals: [Signal<Int, NoError>] = (0 ..< 10).map { index in
            return Signal { subscriber in
                let now = running.modify { $0 + 1 }
                let _ = maxRunning.modify { max($0, now) }
                Queue.concurrentDefaultQueue().after(0.02) {
                    let _ = running.modify { $0 - 1 }
                    subscriber.putNext(index)
                    subscriber.putCompletion()
                }
                return EmptyDisposable
            }
        }
        let done = expectation(description: "finished")
        var last: [Int] = []
        let _ = combineLatestLimitingConcurrency(signals, pendingValue: -1, maxConcurrent: 3).start(next: { values in
            last = values
        }, completed: {
            done.fulfill()
        })
        wait(for: [done], timeout: 5.0)
        XCTAssertEqual(last, Array(0 ..< 10))
        XCTAssertEqual(maxRunning.with { $0 }, 3)
    }

    func testItemsNotStartedReadAsPending() {
        let first = ValuePipe<Int>()
        let signals: [Signal<Int, NoError>] = [first.signal() |> take(1), .single(2)]
        var emitted: [[Int]] = []
        let done = expectation(description: "second value")
        done.assertForOverFulfill = false
        let disposable = combineLatestLimitingConcurrency(signals, pendingValue: 0, maxConcurrent: 1).start(next: { values in
            emitted.append(values)
            if values == [1, 2] {
                done.fulfill()
            }
        })
        Queue.concurrentDefaultQueue().after(0.1) {
            first.putNext(1)
        }
        wait(for: [done], timeout: 2.0)
        disposable.dispose()
        XCTAssertEqual(emitted.first, [1, 0])
        XCTAssertEqual(emitted.last, [1, 2])
    }

    func testFirstErrorFailsTheWhole() {
        let signals: [Signal<Int, Int>] = [.single(1), .fail(7), .single(3)]
        let done = expectation(description: "failed")
        var error: Int?
        let _ = combineLatestLimitingConcurrency(signals, pendingValue: 0, maxConcurrent: 3).start(error: { value in
            error = value
            done.fulfill()
        })
        wait(for: [done], timeout: 2.0)
        XCTAssertEqual(error, 7)
    }

    func testEmptyListCompletesWithNoItems() {
        var values: [[Int]] = []
        let _ = combineLatestLimitingConcurrency([Signal<Int, NoError>](), pendingValue: 0, maxConcurrent: 3).start(next: { values.append($0) })
        XCTAssertEqual(values, [[]])
    }
}

final class ScaledJpegImageTests: XCTestCase {
    private func pngData(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.pngData()!
    }

    // I-10/I-7: the data path downsamples with ImageIO to the long side it is given.
    func testDownsamplesToTheLongSide() {
        let data = pngData(width: 3000, height: 2000)
        let standard = TGItemProviderSignals.scaledJpegImage(with: data, maxPixelSize: shareItemImageMaxPixelSize(highQuality: false))
        let standardSize = (standard?["scaledImageDimensions"] as? NSValue)?.cgSizeValue
        XCTAssertEqual(standardSize?.width, 1280.0)
        XCTAssertNotNil(standard?["scaledImageData"] as? Data)

        let hd = TGItemProviderSignals.scaledJpegImage(with: data, maxPixelSize: shareItemImageMaxPixelSize(highQuality: true))
        XCTAssertEqual((hd?["scaledImageDimensions"] as? NSValue)?.cgSizeValue.width, 2560.0)

        if let jpeg = standard?["scaledImageData"] as? Data, let decoded = UIImage(data: jpeg) {
            XCTAssertEqual(decoded.size.width * decoded.scale, 1280.0)
        } else {
            XCTFail("not a JPEG")
        }
    }

    func testSmallImageKeepsItsSize() {
        let result = TGItemProviderSignals.scaledJpegImage(with: pngData(width: 300, height: 200), maxPixelSize: 1280.0)
        XCTAssertEqual((result?["scaledImageDimensions"] as? NSValue)?.cgSizeValue, CGSize(width: 300.0, height: 200.0))
    }

    func testNotAnImageIsNil() {
        XCTAssertNil(TGItemProviderSignals.scaledJpegImage(with: Data("not an image".utf8), maxPixelSize: 1280.0))
    }
}

final class SharedStorySessionTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        super.setUp()
        self.directory = NSTemporaryDirectory() + "SharedStorySessionTests-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    // I-8: files keep their own extension, so a HEIC or PNG is still a photo and a .mov a video.
    func testKindFollowsTheExtension() {
        XCTAssertTrue(SharedStorySession.isImage(path: "/a/0.jpg"))
        XCTAssertTrue(SharedStorySession.isImage(path: "/a/0.heic"))
        XCTAssertTrue(SharedStorySession.isImage(path: "/a/0.png"))
        XCTAssertFalse(SharedStorySession.isImage(path: "/a/0.mp4"))
        XCTAssertFalse(SharedStorySession.isImage(path: "/a/0.mov"))
        XCTAssertFalse(SharedStorySession.isImage(path: "/a/0"))
    }

    func testFilesAreInSharedOrder() {
        for name in ["10.mov", "2.heic", "1.jpg"] {
            FileManager.default.createFile(atPath: self.directory + "/" + name, contents: Data())
        }
        try! FileManager.default.createDirectory(atPath: self.directory + "/nested", withIntermediateDirectories: true)
        XCTAssertEqual(SharedStorySession.filePaths(sessionPath: self.directory).map { ($0 as NSString).lastPathComponent }, ["1.jpg", "2.heic", "10.mov"])
    }

    // Sessions the app never opened are swept after a day; a fresh one stays.
    func testStaleSessionsAreRemoved() {
        let stale = self.directory + "/1"
        let fresh = self.directory + "/2"
        for path in [stale, fresh] {
            try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let now = Date()
        try! FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2.0 * 24.0 * 60.0 * 60.0)], ofItemAtPath: stale)
        removeStaleSharedStorySessions(path: self.directory, olderThan: 24.0 * 60.0 * 60.0, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh))
    }
}
