import Foundation
import UIKit
import XCTest
import SwiftSignalKit
import AnimationCache
import LottieSettings
@testable import LottieAnimationCache

// A large animation in a menu (the reaction in a reaction's context menu) is cached at every source frame and at
// the screen's scale, except while the system asks the app to use less.
final class LottieCacheQualityTests: XCTestCase {
    private func effective(requestsFull: Bool = true, lowPower: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, cores: Int = 6) -> LottieCacheQuality {
        return LottieCacheQuality.effective(requestsFull: requestsFull, isLowPowerMode: lowPower, thermalState: thermal, processorCount: cores)
    }

    func testASurfaceThatDoesNotAskStaysStandard() {
        XCTAssertEqual(self.effective(requestsFull: false), .standard)
    }

    func testASurfaceThatAsksGetsFullWhenNothingIsConstrained() {
        XCTAssertEqual(self.effective(), .full)
        XCTAssertEqual(self.effective(thermal: .fair), .full)
    }

    func testLowPowerModeKeepsTheStandardCache() {
        XCTAssertEqual(self.effective(lowPower: true), .standard)
    }

    func testSeriousAndCriticalThermalStateKeepTheStandardCache() {
        XCTAssertEqual(self.effective(thermal: .serious), .standard)
        XCTAssertEqual(self.effective(thermal: .critical), .standard)
    }

    func testTwoCoreDevicesKeepTheStandardCache() {
        XCTAssertEqual(self.effective(cores: 2), .standard)
        XCTAssertEqual(self.effective(cores: 0), .standard)
    }

    func testStandardIsWhatUpstreamCaches() {
        XCTAssertEqual(LottieCacheQuality.standard.frameSkip, 2)
        XCTAssertEqual(LottieCacheQuality.standard.pixelScale(screenScale: 3.0), 2.0)
        XCTAssertEqual(LottieCacheQuality.standard.pixelScale(screenScale: 2.0), 2.0)
        XCTAssertEqual(LottieCacheQuality.standard.pixelScale(screenScale: 1.0), 1.0)
        XCTAssertEqual(LottieCacheQuality.standard.cacheSourceId("123"), "123")
    }

    func testFullKeepsEveryFrameAtTheScreensScale() {
        XCTAssertEqual(LottieCacheQuality.full.frameSkip, 1)
        XCTAssertEqual(LottieCacheQuality.full.pixelScale(screenScale: 3.0), 3.0)
        XCTAssertEqual(LottieCacheQuality.full.pixelScale(screenScale: 2.0), 2.0)
    }

    func testFullHasItsOwnCacheEntry() {
        XCTAssertNotEqual(LottieCacheQuality.full.cacheSourceId("123"), LottieCacheQuality.standard.cacheSourceId("123"))
    }

    // MARK: - What is written

    private final class CountingWriter: AnimationCacheItemWriter {
        let queue = Queue(name: "LottieCacheQualityTests")
        var isCancelled: Bool = false
        private(set) var durations: [Double] = []
        private(set) var keyframes: [Bool] = []
        private let finished = DispatchSemaphore(value: 0)

        func add(with drawingBlock: (AnimationCacheItemDrawingSurface) -> Double?, proposedWidth: Int, proposedHeight: Int, insertKeyframe: Bool) {
            let bytesPerRow = proposedWidth * 4
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * proposedHeight)
            bytes.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    return
                }
                let surface = AnimationCacheItemDrawingSurface(argb: base, width: proposedWidth, height: proposedHeight, bytesPerRow: bytesPerRow, length: buffer.count)
                if let duration = drawingBlock(surface) {
                    self.durations.append(duration)
                    self.keyframes.append(insertKeyframe)
                }
            }
        }

        func finish() {
            self.finished.signal()
        }

        func waitUntilFinished() -> Bool {
            return self.finished.wait(timeout: .now() + 60.0) == .success
        }
    }

    private func fixture() throws -> Data {
        let bundles = [Bundle(for: LottieCacheQualityTests.self), Bundle.main] + Bundle.allBundles
        let path = try XCTUnwrap(bundles.lazy.compactMap({ $0.path(forResource: "Slot_M_Berries", ofType: "tgs") }).first, "fixture missing")
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func cache(quality: LottieCacheQuality) throws -> CountingWriter {
        let writer = CountingWriter()
        cacheLottieAnimation(data: try self.fixture(), width: 64, height: 64, keyframeOnly: true, writer: writer, firstFrameOnly: false, customColor: nil, frameSkip: quality.frameSkip)
        XCTAssertTrue(writer.waitUntilFinished())
        return writer
    }

    // The fixture is 60 fps, 180 frames.
    func testStandardCachesEveryOtherFrameAtThirtyFramesPerSecond() throws {
        let writer = try self.cache(quality: .standard)
        XCTAssertEqual(writer.durations.count, 90)
        XCTAssertEqual(writer.durations.first ?? 0.0, 2.0 / 60.0, accuracy: 1e-9)
    }

    func testFullCachesEveryFrameAtSixtyFramesPerSecond() throws {
        let writer = try self.cache(quality: .full)
        XCTAssertEqual(writer.durations.count, 180)
        XCTAssertEqual(writer.durations.first ?? 0.0, 1.0 / 60.0, accuracy: 1e-9)
        // The same running time as the standard cache.
        XCTAssertEqual(writer.durations.reduce(0.0, +), 3.0, accuracy: 1e-6)
    }

    func testTheDefaultStaysUpstreams() throws {
        let writer = CountingWriter()
        cacheLottieAnimation(data: try self.fixture(), width: 64, height: 64, keyframeOnly: true, writer: writer, firstFrameOnly: false, customColor: nil)
        XCTAssertTrue(writer.waitUntilFinished())
        XCTAssertEqual(writer.durations.count, 90)
    }
}
