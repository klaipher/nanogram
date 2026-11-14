import XCTest
@testable import TLottieKit
import CoreGraphics

final class TLottieAnimationDecodeTests: XCTestCase {
    func testValidTgsLoads() throws {
        let url = Bundle.module.url(forResource: "tiny", withExtension: "tgs")!
        let animation = try XCTUnwrap(TLottieAnimation(tgsFileURL: url))
        XCTAssertEqual(animation.dimensions, CGSize(width: 100, height: 100))
        XCTAssertEqual(animation.frameRate, 30)
        XCTAssertEqual(animation.frameCount, 30)
        XCTAssertEqual(animation.duration, 1.0, accuracy: 0.0001)
    }

    func testRandomBytesReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("bogus-\(UUID().uuidString).tgs")
        let bogus = Data((0..<256).map { _ in UInt8.random(in: 0...255) })
        try bogus.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(TLottieAnimation(tgsFileURL: url))
    }

    func testRawJsonReturnsNil() throws {
        // We accept TGS (gzipped) only — raw JSON should fail the gunzip step.
        let url = Bundle.module.url(forResource: "tiny", withExtension: "json")!
        XCTAssertNil(TLottieAnimation(tgsFileURL: url))
    }

    func testDotLottieZipReturnsNil() throws {
        // A sticker whose payload is a dotLottie zip (valid Lottie JSON inside) is refused:
        // stickers are JSON, and a dotLottie archive is never handed to tlottie, which parses JSON only.
        let url = Bundle.module.url(forResource: "dotlottie", withExtension: "tgs")!
        XCTAssertNil(TLottieAnimation(tgsFileURL: url))
    }

    func testRenderFrameProducesNonEmptyImage() throws {
        let url = Bundle.module.url(forResource: "tiny", withExtension: "tgs")!
        let animation = try XCTUnwrap(TLottieAnimation(tgsFileURL: url))
        let image = animation.renderFrame(index: 0, size: CGSize(width: 32, height: 32), scale: 1.0)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 32)
        XCTAssertEqual(image?.height, 32)
    }
}
