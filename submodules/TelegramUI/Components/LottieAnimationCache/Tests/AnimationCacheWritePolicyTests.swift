import Foundation
import UIKit
import XCTest
import SwiftSignalKit
import AnimationCache
@testable import LottieAnimationCache

// A gift in a grid is cached at the pixels it shows and is converted only once it has stayed.
final class AnimationCacheWritePolicyTests: XCTestCase {
    private final class NullWriter: AnimationCacheItemWriter {
        let queue = Queue(name: "AnimationCacheWritePolicyTests")
        var isCancelled: Bool = false
        func add(with drawingBlock: (AnimationCacheItemDrawingSurface) -> Double?, proposedWidth: Int, proposedHeight: Int, insertKeyframe: Bool) {
        }
        func finish() {
        }
    }

    private func options() -> AnimationCacheFetchOptions {
        return AnimationCacheFetchOptions(size: CGSize(width: 64.0, height: 64.0), writer: NullWriter(), firstFrameOnly: false)
    }

    // MARK: - Pixel size

    func testAGridGiftIsCachedAtTheDisplayedPixelsOnATripleScaleScreen() {
        // 88 pt shown, 176 pt asked for by the gift cell, cached at 2x: 352 px. The cell shows 264.
        let size = AnimationCacheWritePolicy.pixelSize(requested: CGSize(width: 352.0, height: 352.0), displayPointSize: CGSize(width: 88.0, height: 88.0), screenScale: 3.0)
        XCTAssertEqual(size, CGSize(width: 264.0, height: 264.0))
    }

    func testAGridGiftIsCachedAtTheDisplayedPixelsOnADoubleScaleScreen() {
        let size = AnimationCacheWritePolicy.pixelSize(requested: CGSize(width: 352.0, height: 352.0), displayPointSize: CGSize(width: 88.0, height: 88.0), screenScale: 2.0)
        XCTAssertEqual(size, CGSize(width: 176.0, height: 176.0))
    }

    func testTheRequestedSizeIsNeverRaised() {
        let size = AnimationCacheWritePolicy.pixelSize(requested: CGSize(width: 100.0, height: 100.0), displayPointSize: CGSize(width: 88.0, height: 88.0), screenScale: 3.0)
        XCTAssertEqual(size, CGSize(width: 100.0, height: 100.0))
    }

    func testASurfaceWithoutADisplaySizeKeepsWhatItAsksFor() {
        let requested = CGSize(width: 352.0, height: 352.0)
        XCTAssertEqual(AnimationCacheWritePolicy.pixelSize(requested: requested, displayPointSize: nil, screenScale: 3.0), requested)
        XCTAssertEqual(AnimationCacheWritePolicy.pixelSize(requested: requested, displayPointSize: CGSize(), screenScale: 3.0), requested)
        XCTAssertEqual(AnimationCacheWritePolicy.pixelSize(requested: requested, displayPointSize: CGSize(width: 88.0, height: 88.0), screenScale: 0.0), requested)
    }

    func testAFractionalDisplaySizeRoundsUp() {
        let size = AnimationCacheWritePolicy.pixelSize(requested: CGSize(width: 400.0, height: 400.0), displayPointSize: CGSize(width: 77.4, height: 77.4), screenScale: 3.0)
        XCTAssertEqual(size, CGSize(width: 233.0, height: 233.0))
    }

    // MARK: - Start delay

    func testOnlyGridCellsWait() {
        XCTAssertGreaterThan(AnimationCacheWritePolicy.startDelay(for: .scrollingGrid), 0.0)
        XCTAssertEqual(AnimationCacheWritePolicy.startDelay(for: .single), 0.0)
    }

    func testNoDelayReturnsTheFetchItself() {
        var calls = 0
        let fetch = AnimationCacheWritePolicy.deferred(delay: 0.0, fetch: { _ in
            calls += 1
            return EmptyDisposable
        })
        let _ = fetch(self.options())
        XCTAssertEqual(calls, 1)
    }

    func testADelayedFetchStartsAfterTheDelay() {
        let started = expectation(description: "started")
        let callCount = Atomic<Int>(value: 0)
        let fetch = AnimationCacheWritePolicy.deferred(delay: 0.05, fetch: { _ in
            let _ = callCount.modify { $0 + 1 }
            started.fulfill()
            return EmptyDisposable
        })
        let _ = fetch(self.options())
        XCTAssertEqual(callCount.with { $0 }, 0)
        wait(for: [started], timeout: 5.0)
        XCTAssertEqual(callCount.with { $0 }, 1)
    }

    func testAFetchDisposedBeforeTheDelayNeverStarts() {
        let callCount = Atomic<Int>(value: 0)
        let fetch = AnimationCacheWritePolicy.deferred(delay: 0.1, fetch: { _ in
            let _ = callCount.modify { $0 + 1 }
            return EmptyDisposable
        })
        let disposable = fetch(self.options())
        disposable.dispose()
        let passed = expectation(description: "passed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            passed.fulfill()
        }
        wait(for: [passed], timeout: 5.0)
        XCTAssertEqual(callCount.with { $0 }, 0)
    }

    func testDisposingAfterTheStartDisposesTheRunningFetch() {
        let started = expectation(description: "started")
        let innerDisposed = expectation(description: "disposed")
        let fetch = AnimationCacheWritePolicy.deferred(delay: 0.02, fetch: { _ in
            started.fulfill()
            return ActionDisposable {
                innerDisposed.fulfill()
            }
        })
        let disposable = fetch(self.options())
        wait(for: [started], timeout: 5.0)
        disposable.dispose()
        wait(for: [innerDisposed], timeout: 5.0)
    }
}
