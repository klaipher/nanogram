import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

final class MediaBoxIncrementalDataTests: XCTestCase {
    private var queue: Queue!
    private var basePath: String!
    private var manager: MediaBoxFileManager!
    private var context: MediaBoxFileContextV2Impl!
    private var fetch: Disposable!
    private var pipe: ValuePipe<MediaResourceDataFetchResult>!
    private var subscriptions: [Disposable] = []

    override func setUp() {
        super.setUp()
        self.queue = Queue(name: "MediaBoxIncrementalDataTests")
        self.basePath = NSTemporaryDirectory() + "MediaBoxIncrementalDataTests-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: self.basePath, withIntermediateDirectories: true)
        self.manager = MediaBoxFileManager(queue: self.queue)
        self.pipe = ValuePipe()
        self.queue.sync {
            self.context = MediaBoxFileContextV2Impl(queue: self.queue, manager: self.manager, storageBox: nil, resourceId: Data("resource".utf8), path: self.basePath + "/resource", partialPath: self.basePath + "/resource_partial", metaPath: self.basePath + "/resource_partial.meta")
        }
    }

    override func tearDown() {
        self.subscriptions.forEach { $0.dispose() }
        self.fetch?.dispose()
        self.queue.sync { self.context = nil }
        self.manager = nil
        try? FileManager.default.removeItem(atPath: self.basePath)
        super.tearDown()
    }

    private func beginFetch() {
        self.queue.sync {
            self.fetch = self.context.fetchedFullRange(fetch: { _ in
                self.pipe.signal() |> castError(MediaResourceDataFetchError.self)
            }, error: { _ in XCTFail("unexpected fetch error") }, completed: {})
        }
    }

    @discardableResult
    private func observe(range: Range<Int64> = 0 ..< Int64.max, incremental: Bool = true, wait: Bool = false, next: @escaping (MediaResourceData) -> Void) -> Disposable {
        var subscription: Disposable!
        self.queue.sync {
            subscription = self.context.data(range: range, incremental: incremental, waitUntilAfterInitialFetch: wait, next: next)
        }
        self.subscriptions.append(subscription)
        return subscription
    }

    private func emit(_ result: MediaResourceDataFetchResult) {
        self.pipe.putNext(result)
        self.queue.sync {}
    }

    private func write(_ offset: Int64, _ values: [UInt8], complete: Bool = false) {
        self.emit(.dataPart(resourceOffset: offset, data: Data(values), range: 0 ..< Int64(values.count), complete: complete))
    }

    func testIncompletePrefixGrowsButCompleteModeWaits() {
        var incremental: [MediaResourceData] = []
        var complete: [MediaResourceData] = []
        self.observe { incremental.append($0) }
        self.observe(incremental: false) { complete.append($0) }
        self.beginFetch()
        self.write(0, [1, 2, 3, 4])
        self.write(4, [5, 6])
        self.queue.sync {
            XCTAssertEqual(incremental.map(\.size), [0, 4, 6])
            XCTAssertTrue(incremental.allSatisfy { !$0.complete })
            XCTAssertEqual(complete.map(\.size), [0])
        }
    }

    func testOutOfOrderWritesExposeOnlyContiguousPrefixAndFillingHoleAdvancesIt() {
        var values: [MediaResourceData] = []
        self.observe { values.append($0) }
        self.beginFetch()
        self.write(8, [9, 10, 11, 12])
        self.queue.sync { XCTAssertEqual(values.map(\.size), [0]) }
        self.write(0, [1, 2, 3, 4])
        self.queue.sync { XCTAssertEqual(values.map(\.size), [0, 4]) }
        self.write(4, [5, 6, 7, 8])
        self.queue.sync {
            XCTAssertEqual(values.map(\.size), [0, 4, 12])
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: values.last!.path)), Data(1 ... 12))
        }
    }

    func testFiniteRangeKeepsCompleteRangeSemantics() {
        var values: [MediaResourceData] = []
        self.observe(range: 4 ..< 12, incremental: false) { values.append($0) }
        self.beginFetch()
        self.write(4, [5, 6, 7, 8])
        self.queue.sync { XCTAssertEqual(values.map(\.size), [0]) }
        self.write(8, [9, 10, 11, 12])
        self.queue.sync {
            XCTAssertEqual(values.map(\.size), [0, 8])
            XCTAssertEqual(values.last?.offset, 4)
            XCTAssertEqual(values.last?.complete, true)
        }
    }

    func testHeaderReplacementRetainsPrefixAndCompletionPublishesFinalBytes() {
        var values: [MediaResourceData] = []
        self.observe { values.append($0) }
        self.beginFetch()
        self.write(0, [1, 2, 3, 4, 5, 6, 7, 8])
        self.emit(.replaceHeader(data: Data([9, 10]), range: 0 ..< 2))
        self.queue.sync { XCTAssertEqual(values.map(\.size), [0, 8]) }
        self.emit(.resourceSizeUpdated(8))
        self.queue.sync {
            XCTAssertEqual(values.map(\.size), [0, 8, 8])
            XCTAssertEqual(values.last?.complete, true)
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: values.last!.path)), Data([9, 10, 3, 4, 5, 6, 7, 8]))
        }
    }

    func testFinalDataPartCompletesIncrementalAndCompleteSubscribers() {
        var incremental: [MediaResourceData] = []
        var complete: [MediaResourceData] = []
        self.observe { incremental.append($0) }
        self.observe(incremental: false) { complete.append($0) }
        self.beginFetch()
        self.write(0, [1, 2])
        self.write(2, [3, 4], complete: true)
        self.queue.sync {
            XCTAssertEqual(incremental.last?.size, 4)
            XCTAssertEqual(incremental.last?.complete, true)
            XCTAssertEqual(complete.map(\.size), [0, 4])
            XCTAssertEqual(complete.last?.complete, true)
        }
    }

    func testCancelledObserverReceivesNoLaterPrefixOrCompletion() {
        var sizes: [Int64] = []
        let subscription = self.observe { sizes.append($0.size) }
        self.beginFetch()
        self.write(0, [1, 2])
        subscription.dispose()
        self.queue.sync {}
        self.write(2, [3, 4], complete: true)
        self.queue.sync { XCTAssertEqual(sizes, [0, 2]) }
    }

    func testWaitingForInitialFetchSuppressesEmptyBeforeFetchButReportsPrefix() {
        var values: [MediaResourceData] = []
        self.observe(wait: true) { values.append($0) }
        self.queue.sync { XCTAssertTrue(values.isEmpty) }
        self.beginFetch()
        self.write(0, [1, 2, 3])
        self.queue.sync {
            XCTAssertEqual(values.last?.size, 3)
            XCTAssertFalse(values.last!.complete)
        }
    }
}
