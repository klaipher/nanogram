import XCTest
@testable import RLottieKit
import CoreGraphics
import Foundation
import RLottieCore

/// Renders a real Telegram sticker and compares it with a coarse reference taken from
/// rlottie v0.2, so an rlottie update that breaks rendering fails here. The reference is
/// an 8x8 grid of mean alpha values per frame (64x64 render), compared with a tolerance
/// because antialiasing may legitimately differ by a few levels between versions.
final class StickerRenderRegressionTests: XCTestCase {
    private static let size = 64
    private static let grid = 8

    // Recorded with rlottie v0.2 (Samsung bf3d272) at frames 0, 78, 155.
    private static let reference: [Int: [Int]] = [
        0: [
            0, 0, 0, 0, 0, 0, 0, 0, 60, 126, 21, 41, 76, 156, 0, 0,
            159, 252, 123, 146, 252, 252, 62, 0, 24, 147, 187, 171, 251, 252, 87, 0,
            0, 158, 252, 213, 247, 250, 191, 9, 61, 227, 174, 152, 169, 223, 70, 0,
            50, 195, 144, 173, 172, 191, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ],
        78: [
            0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 41, 0, 79, 182, 151, 13,
            110, 201, 47, 32, 162, 253, 252, 28, 139, 236, 189, 183, 131, 252, 243, 58,
            51, 121, 150, 189, 154, 251, 233, 64, 62, 204, 104, 39, 118, 227, 82, 42,
            51, 196, 120, 208, 210, 209, 13, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ],
        155: [
            0, 0, 0, 0, 0, 0, 0, 0, 58, 117, 36, 54, 94, 183, 3, 0,
            161, 252, 136, 116, 252, 252, 77, 0, 28, 151, 185, 143, 251, 252, 84, 0,
            0, 156, 252, 200, 248, 249, 179, 5, 62, 227, 177, 134, 160, 223, 70, 0,
            51, 197, 146, 173, 172, 192, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ],
    ]

    private func animation() throws -> LottieAnimation {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sticker_lottie", withExtension: "tgs"))
        return try XCTUnwrap(LottieAnimation(tgsFileURL: url))
    }

    private func alphaGrid(_ animation: LottieAnimation, frame: Int) throws -> [Int] {
        let image = try XCTUnwrap(animation.renderFrame(index: frame, size: CGSize(width: Self.size, height: Self.size), scale: 1))
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let cell = Self.size / Self.grid
        var result: [Int] = []
        for gy in 0..<Self.grid {
            for gx in 0..<Self.grid {
                var sum = 0
                for y in gy * cell..<(gy + 1) * cell {
                    for x in gx * cell..<(gx + 1) * cell {
                        // BGRA premultiplied: alpha is the 4th byte.
                        sum += Int(data[y * image.bytesPerRow + x * 4 + 3])
                    }
                }
                result.append(sum / (cell * cell))
            }
        }
        return result
    }

    func testStickerMetadata() throws {
        let a = try animation()
        XCTAssertEqual(a.dimensions, CGSize(width: 512, height: 512))
        XCTAssertEqual(a.frameRate, 60)
        XCTAssertEqual(a.frameCount, 156)
    }

    func testStickerFramesMatchReference() throws {
        let a = try animation()
        if ProcessInfo.processInfo.environment["RLOTTIE_RECORD"] != nil {
            for frame in [0, 78, 155] {
                print("RLOTTIE_REFERENCE \(frame): \(try alphaGrid(a, frame: frame))")
            }
            return
        }
        XCTAssertFalse(Self.reference.isEmpty)
        for (frame, expected) in Self.reference {
            let actual = try alphaGrid(a, frame: frame)
            XCTAssertGreaterThan(actual.reduce(0, +), 0, "frame \(frame) rendered empty")
            for (i, (e, v)) in zip(expected, actual).enumerated() {
                XCTAssertLessThanOrEqual(abs(e - v), 6, "frame \(frame) cell \(i): expected \(e), got \(v)")
            }
        }
    }
}
