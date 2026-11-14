import XCTest
import CoreGraphics
import Foundation
@testable import TLottieKit

/// Speed of the two costs a playing chat sticker has on the watch: parsing the TGS once,
/// and rendering one frame per tick at bubble size (120 pt at 2x = 240 px).
/// Prints numbers; run in release (`swift test -c release -Xswiftc -enable-testing
/// --filter MediaRenderBenchmarkTests`), debug builds of tlottie are ~10x slower.
final class MediaRenderBenchmarkTests: XCTestCase {
    private let size = CGSize(width: 120, height: 120)
    private let scale: CGFloat = 2

    private func url() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "sticker_lottie", withExtension: "tgs"))
    }

    private func milliseconds(_ iterations: Int, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000 / Double(iterations)
    }

    func testBenchmarkLoad() throws {
        let url = try url()
        let ms = milliseconds(20) { _ = TLottieAnimation(tgsFileURL: url) }
        print(String(format: "BENCH lottie load: %.3f ms", ms))
    }

    func testBenchmarkRenderFrame() throws {
        let animation = try XCTUnwrap(TLottieAnimation(tgsFileURL: try url()))
        var index = 0
        let ms = milliseconds(300) {
            _ = animation.renderFrame(index: index % animation.frameCount, size: size, scale: scale)
            index += 1
        }
        print(String(format: "BENCH lottie renderFrame 240px: %.3f ms", ms))
    }

    func testRenderedFrameKeepsItsPixels() throws {
        // The CGImage owns its buffer: pixels must survive the next render and the
        // animation itself being released.
        var animation: TLottieAnimation? = try XCTUnwrap(TLottieAnimation(tgsFileURL: try url()))
        let first = try XCTUnwrap(animation?.renderFrame(index: 0, size: size, scale: scale))
        let before = try XCTUnwrap(first.dataProvider?.data as Data?)
        _ = animation?.renderFrame(index: 78, size: size, scale: scale)
        animation = nil
        let after = try XCTUnwrap(first.dataProvider?.data as Data?)
        XCTAssertEqual(before, after)
        XCTAssertEqual(first.width, 240)
        XCTAssertEqual(first.height, 240)
        XCTAssertGreaterThan(before.reduce(0) { $0 + Int($1) }, 0)
    }
}
