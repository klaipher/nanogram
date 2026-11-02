import Foundation
import XCTest
import SwiftSignalKit
import AnimationCache
@testable import DCTAnimationCacheImpl

private typealias Support = DCTAnimationCacheTestSupport

// Timing of the cache writer and of playback on real emoji/sticker frames.
// Prints BENCH lines; asserts nothing about speed.
final class DCTAnimationCacheBenchmarkTests: XCTestCase {
    func testBenchmarkWriteAndPlayback() throws {
        let basePath = Support.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: basePath)
            try? FileManager.default.removeItem(atPath: basePath + "-temp")
        }
        let cache = Support.makeCache(basePath: basePath)

        for (name, width, height) in [("emoji62_v6", 62, 62), ("sticker160_v6", 160, 160)] {
            let sourceId = "fixture-\(name)"
            _ = try Support.installFixture(name, basePath: basePath, sourceId: sourceId, width: width, height: height)
            guard let item = Support.getItem(cache: cache, sourceId: sourceId, width: width, height: height, fetch: Support.failingFetch) else {
                XCTFail()
                continue
            }
            let frames = Support.decodeFrames(item)

            for (formatVersion, codec): (UInt32, DCTAnimationCacheCodec?) in [(6, nil), (7, nil), (8, .lzbitmap), (8, .lzmesh)] {
            if codec == .lzmesh, #unavailable(iOS 27.0) {
                continue
            }
            dctAnimationCacheWriterCodecOverride = codec
            dctAnimationCacheWriterFormatVersion = formatVersion
            defer {
                dctAnimationCacheWriterFormatVersion = 8
                dctAnimationCacheWriterCodecOverride = nil
            }
            let writeIterations = 8
            var bytes = 0
            var written: AnimationCacheItem?
            let writeStart = CFAbsoluteTimeGetCurrent()
            for i in 0 ..< writeIterations {
                written = Support.writeFrames(cache: cache, sourceId: "bench-\(name)-\(formatVersion)-\(String(describing: codec))-\(i)", width: width, height: height, frames: frames)
                let path = Support.itemPath(basePath: basePath, sourceId: "bench-\(name)-\(formatVersion)-\(String(describing: codec))-\(i)", width: width, height: height)
                bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1
            }
            let writeTime = (CFAbsoluteTimeGetCurrent() - writeStart) / Double(writeIterations)

            guard let written else {
                XCTFail()
                return
            }
            let loops = 20
            let playStart = CFAbsoluteTimeGetCurrent()
            for _ in 0 ..< loops * written.numFrames {
                let _ = written.advance(advance: .frames(1), requestedFormat: .rgba)
            }
            let playTime = (CFAbsoluteTimeGetCurrent() - playStart) / Double(loops * written.numFrames)

            let fixtureStart = CFAbsoluteTimeGetCurrent()
            for _ in 0 ..< loops * item.numFrames {
                let _ = item.advance(advance: .frames(1), requestedFormat: .rgba)
            }
            let fixtureTime = (CFAbsoluteTimeGetCurrent() - fixtureStart) / Double(loops * item.numFrames)

            Support.log(String(format: "BENCH %@ format=%d codec=%@ frames=%d write=%.2fms/item bytes=%d play=%.1fus/frame playV6Fixture=%.1fus/frame", name, Int(formatVersion), String(describing: codec), frames.count, writeTime * 1000.0, bytes, playTime * 1e6, fixtureTime * 1e6))
            }
        }
    }
}
