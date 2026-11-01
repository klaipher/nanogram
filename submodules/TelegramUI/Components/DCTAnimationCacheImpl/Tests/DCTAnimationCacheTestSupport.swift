import Foundation
import XCTest
import CryptoUtils
import SwiftSignalKit
import AnimationCache
@testable import DCTAnimationCacheImpl

final class DCTAnimationCacheTestSupport {
    // stdout of the test process is not kept in the bazel log of a passing run.
    static func log(_ string: String) {
        FileHandle.standardError.write((string + "\n").data(using: .utf8)!)
    }

    static func fixturePath(_ name: String) throws -> String {
        let bundles = [Bundle(for: DCTAnimationCacheTestSupport.self), Bundle.main] + Bundle.allBundles
        for bundle in bundles {
            if let path = bundle.path(forResource: name, ofType: "bin") {
                return path
            }
        }
        throw XCTSkip("\(name).bin is not in the test bundle")
    }

    static func md5Hex(_ string: String) -> String {
        let data = string.data(using: .utf8)!
        let hash = data.withUnsafeBytes { bytes -> Data in
            return CryptoMD5(bytes.baseAddress!, Int32(bytes.count))
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func makeTempDirectory() -> String {
        let path = NSTemporaryDirectory() + "dct-cache-tests-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func makeCache(basePath: String) -> DCTAnimationCacheImpl {
        let tempPath = basePath + "-temp"
        try? FileManager.default.createDirectory(atPath: tempPath, withIntermediateDirectories: true)
        return DCTAnimationCacheImpl(basePath: basePath, allocateTempFile: {
            return tempPath + "/" + UUID().uuidString
        }, updateStorageStats: { _, _ in
        })
    }

    static func itemPath(basePath: String, sourceId: String, width: Int, height: Int) -> String {
        let hash = md5Hex(sourceId)
        return "\(basePath)/\(hash.prefix(2))/\(hash)_\(width)x\(height)"
    }

    static func installFixture(_ name: String, basePath: String, sourceId: String, width: Int, height: Int) throws -> String {
        let source = try fixturePath(name)
        let path = itemPath(basePath: basePath, sourceId: sourceId, width: width, height: height)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: source, toPath: path)
        return path
    }

    // Waits for the final result of `get`.
    // A failed conversion never delivers a final result, hence the timeout.
    static func getItem(cache: AnimationCache, sourceId: String, width: Int, height: Int, timeout: Double = 60.0, fetch: @escaping (AnimationCacheFetchOptions) -> Disposable) -> AnimationCacheItem? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: AnimationCacheItem?
        let disposable = cache.get(sourceId: sourceId, size: CGSize(width: width, height: height), fetch: fetch).start(next: { value in
            if value.isFinal {
                result = value.item
                semaphore.signal()
            }
        })
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        disposable.dispose()
        if waitResult == .timedOut {
            return nil
        }
        return result
    }

    static func failingFetch(_ options: AnimationCacheFetchOptions) -> Disposable {
        XCTFail("fetch must not be called for a cached item")
        options.writer.finish()
        return EmptyDisposable
    }

    // Frames decoded as premultiplied ARGB, one Data per frame.
    static func decodeFrames(_ item: AnimationCacheItem, count: Int? = nil) -> [(data: Data, width: Int, height: Int, bytesPerRow: Int, duration: Double)] {
        var result: [(data: Data, width: Int, height: Int, bytesPerRow: Int, duration: Double)] = []
        for _ in 0 ..< (count ?? item.numFrames) {
            guard let frame = item.advance(advance: .frames(1), requestedFormat: .rgba) else {
                break
            }
            guard case let .rgba(data, width, height, bytesPerRow) = frame.frame.format else {
                break
            }
            result.append((data, width, height, bytesPerRow, frame.frame.duration))
        }
        return result
    }

    static func storedFormatVersion(path: String) -> UInt32? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= 4 else {
            return nil
        }
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: 0 ..< 4) }
        return value
    }

    static func checksum(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        data.withUnsafeBytes { bytes in
            for byte in bytes.bindMemory(to: UInt8.self) {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
        }
        return hash
    }

    static func checksum(frames: [(data: Data, width: Int, height: Int, bytesPerRow: Int, duration: Double)]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for frame in frames {
            hash = (hash ^ checksum(frame.data)) &* 0x100000001b3
        }
        return hash
    }

    // Writes ARGB frames through the cache's own writer, the way cacheVideoAnimation does.
    static func writeFrames(cache: AnimationCache, sourceId: String, width: Int, height: Int, frames: [(data: Data, width: Int, height: Int, bytesPerRow: Int, duration: Double)], keyframeEvery: Int? = nil) -> AnimationCacheItem? {
        return getItem(cache: cache, sourceId: sourceId, width: width, height: height, fetch: { options in
            let writer = options.writer
            writer.queue.async {
                for (index, frame) in frames.enumerated() {
                    writer.add(with: { surface in
                        frame.data.withUnsafeBytes { bytes in
                            let source = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                            let copyBytesPerRow = min(surface.bytesPerRow, frame.bytesPerRow)
                            for y in 0 ..< min(surface.height, frame.height) {
                                memcpy(surface.argb.advanced(by: y * surface.bytesPerRow), source.advanced(by: y * frame.bytesPerRow), copyBytesPerRow)
                            }
                        }
                        return frame.duration
                    }, proposedWidth: width, proposedHeight: height, insertKeyframe: keyframeEvery.flatMap { index % $0 == 0 } ?? false)
                }
                writer.finish()
            }
            return EmptyDisposable
        })
    }
}
