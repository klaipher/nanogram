import XCTest
import CoreMedia
import CoreVideo
import Camera
@testable import CameraNeo

/// Debug Settings ▸ "Circle Colour Decode" (`NeoCameraImpl.RoundVideoCameraMatrix`): the matrix the processor
/// decodes the camera's YCbCr with. The camera tags its 8-bit 4:2:0 buffers BT.601, but decoding them by that tag
/// turned skin and lips ~7-9° towards magenta against Legacy (the camera's own BGRA conversion) and the official
/// app; re-decoding as BT.709 matched them to ~1 ΔE a*b*.
final class RoundVideoDecodeMatrixTests: XCTestCase {
    private let tag601 = kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
    private let tag709 = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
    private let tag2020 = kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
    private let tag240M = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String
    private let fullRange = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    private let videoRange = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// `RoundVideoFrameProcessor.colorConversion(for:)` as it was before the setting existed, verbatim.
    private func oldConversion(cameraTag matrixName: String?, pixelFormat: OSType) -> ColorConversion {
        let kr: Float
        let kb: Float
        if matrixName == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
            kr = 0.299
            kb = 0.114
        } else if matrixName == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {
            kr = 0.2627
            kb = 0.0593
        } else {
            kr = 0.2126
            kb = 0.0722
        }

        let kg = 1.0 - kr - kb
        let isFullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let yScale: Float = isFullRange ? 1.0 : 255.0 / 219.0
        let chromaScale: Float = isFullRange ? 1.0 : 255.0 / 224.0
        let yOffset: Float = isFullRange ? 0.0 : -16.0 / 255.0
        let chromaOffset: Float = -128.0 / 255.0

        return ColorConversion(
            row0: SIMD4<Float>(yScale, 0.0, 2.0 * (1.0 - kr) * chromaScale, 0.0),
            row1: SIMD4<Float>(
                yScale,
                -2.0 * kb * (1.0 - kb) / kg * chromaScale,
                -2.0 * kr * (1.0 - kr) / kg * chromaScale,
                0.0
            ),
            row2: SIMD4<Float>(yScale, 2.0 * (1.0 - kb) * chromaScale, 0.0, 0.0),
            offset: SIMD4<Float>(yOffset, chromaOffset, chromaOffset, 0.0)
        )
    }

    /// The shader's decode (`readRgb` in CameraNeo.metal): offset, then the matrix rows, on 0...1 samples.
    private func decode(_ conversion: ColorConversion, y: Float, cb: Float, cr: Float) -> (r: Float, g: Float, b: Float) {
        let v = SIMD4<Float>(y, cb, cr, 0.0) + conversion.offset
        return ((conversion.row0 * v).sum(), (conversion.row1 * v).sum(), (conversion.row2 * v).sum())
    }

    /// Full-range BT.709 encode of an 8-bit colour, as 0...1 samples.
    private func encode709FullRange(_ rgb: (Float, Float, Float)) -> (y: Float, cb: Float, cr: Float) {
        let r = rgb.0 / 255.0
        let g = rgb.1 / 255.0
        let b = rgb.2 / 255.0
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return (y, (b - y) / 1.8556 + 128.0 / 255.0, (r - y) / 1.5748 + 128.0 / 255.0)
    }

    func testDefaultDecodesA601TaggedFullRangeCameraBufferAsBT709() {
        XCTAssertEqual(RoundVideoFrameProcessor.decodeMatrix(setting: .bt709, cameraTag: self.tag601), .bt709)

        let conversion = RoundVideoFrameProcessor.colorConversion(setting: .bt709, cameraTag: self.tag601, pixelFormat: self.fullRange)
        XCTAssertEqual(conversion, self.oldConversion(cameraTag: self.tag709, pixelFormat: self.fullRange))
        XCTAssertNotEqual(conversion, self.oldConversion(cameraTag: self.tag601, pixelFormat: self.fullRange))
        XCTAssertEqual(conversion.row0.z, 1.5748, accuracy: 1e-5)
        XCTAssertEqual(conversion.row2.y, 1.8556, accuracy: 1e-5)

        // A skin tone encoded with 709 decodes back to itself.
        let skin: (Float, Float, Float) = (220.0, 160.0, 130.0)
        let encoded = self.encode709FullRange(skin)
        let decoded = self.decode(conversion, y: encoded.y, cb: encoded.cb, cr: encoded.cr)
        XCTAssertEqual(decoded.r * 255.0, skin.0, accuracy: 0.01)
        XCTAssertEqual(decoded.g * 255.0, skin.1, accuracy: 0.01)
        XCTAssertEqual(decoded.b * 255.0, skin.2, accuracy: 0.01)

        // Decoded by the 601 tag, the same samples come out less green and bluer, towards magenta: about
        // (214.6, 155.7, 131.8).
        let old = self.decode(self.oldConversion(cameraTag: self.tag601, pixelFormat: self.fullRange), y: encoded.y, cb: encoded.cb, cr: encoded.cr)
        XCTAssertLessThan(old.g * 255.0, skin.1 - 4.0)
        XCTAssertGreaterThan(old.b * 255.0, skin.2 + 1.5)
    }

    func testCameraTagReproducesTheOldConversionExactly() {
        for tag in [self.tag601, self.tag709, self.tag2020, self.tag240M, nil] as [String?] {
            for pixelFormat in [self.fullRange, self.videoRange] {
                XCTAssertEqual(
                    RoundVideoFrameProcessor.colorConversion(setting: .cameraTag, cameraTag: tag, pixelFormat: pixelFormat),
                    self.oldConversion(cameraTag: tag, pixelFormat: pixelFormat),
                    "\(tag ?? "untagged") \(roundVideoFourCharCode(pixelFormat))"
                )
            }
        }
    }

    func testBT601SettingDecodesSDRWithBT601() {
        for tag in [self.tag601, self.tag709, nil] as [String?] {
            XCTAssertEqual(RoundVideoFrameProcessor.decodeMatrix(setting: .bt601, cameraTag: tag), .bt601)
            XCTAssertEqual(
                RoundVideoFrameProcessor.colorConversion(setting: .bt601, cameraTag: tag, pixelFormat: self.fullRange),
                self.oldConversion(cameraTag: self.tag601, pixelFormat: self.fullRange)
            )
        }
    }

    func testBT709SettingDecodesEverySDRTagWithBT709() {
        for tag in [self.tag601, self.tag709, self.tag240M, nil] as [String?] {
            XCTAssertEqual(RoundVideoFrameProcessor.decodeMatrix(setting: .bt709, cameraTag: tag), .bt709, tag ?? "untagged")
        }
    }

    func testBT2020TagIsKeptUnderEverySetting() {
        for setting in [NeoCameraImpl.RoundVideoCameraMatrix.bt709, .cameraTag, .bt601] {
            XCTAssertEqual(RoundVideoFrameProcessor.decodeMatrix(setting: setting, cameraTag: self.tag2020), .bt2020)
            for pixelFormat in [self.fullRange, self.videoRange] {
                XCTAssertEqual(
                    RoundVideoFrameProcessor.colorConversion(setting: setting, cameraTag: self.tag2020, pixelFormat: pixelFormat),
                    self.oldConversion(cameraTag: self.tag2020, pixelFormat: pixelFormat)
                )
            }
        }
    }

    func testRangeFollowsThePixelFormatUnderEverySetting() {
        for setting in [NeoCameraImpl.RoundVideoCameraMatrix.bt709, .cameraTag, .bt601] {
            let full = RoundVideoFrameProcessor.colorConversion(setting: setting, cameraTag: self.tag601, pixelFormat: self.fullRange)
            XCTAssertEqual(full.row0.x, 1.0)
            XCTAssertEqual(full.offset, SIMD4<Float>(0.0, -128.0 / 255.0, -128.0 / 255.0, 0.0))

            let video = RoundVideoFrameProcessor.colorConversion(setting: setting, cameraTag: self.tag601, pixelFormat: self.videoRange)
            XCTAssertEqual(video.row0.x, 255.0 / 219.0)
            XCTAssertEqual(video.offset, SIMD4<Float>(-16.0 / 255.0, -128.0 / 255.0, -128.0 / 255.0, 0.0))

            // The same matrix as the full-range decode, scaled for video-range chroma.
            XCTAssertEqual(video.row2.y, full.row2.y * 255.0 / 224.0, accuracy: 1e-6)
            XCTAssertEqual(video.row0.z, full.row0.z * 255.0 / 224.0, accuracy: 1e-6)
        }
    }

    func testDiagnosticsDescribeTheCameraBufferAndTheDecode() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 960, self.fullRange, nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDescription), noErr)

        let description = roundVideoCameraBufferColorDescription(pixelBuffer: buffer, formatDescription: formatDescription, setting: .bt709)
        print("RoundVideoDecodeMatrixTests: \(description)")
        XCTAssertTrue(description.contains("pixelFormat=420f"), description)
        XCTAssertTrue(description.contains("buffer=1280x960"), description)
        XCTAssertTrue(description.contains("matrix=\(self.tag601)"), description)
        XCTAssertTrue(description.contains("primaries=\(kCVImageBufferColorPrimaries_ITU_R_709_2 as String)"), description)
        XCTAssertTrue(description.contains("transfer=\(kCVImageBufferTransferFunction_ITU_R_709_2 as String)"), description)
        XCTAssertTrue(description.contains("setting=bt709, decode=bt709 full range"), description)

        let tagged = roundVideoCameraBufferColorDescription(pixelBuffer: buffer, formatDescription: formatDescription, setting: .cameraTag)
        XCTAssertTrue(tagged.contains("setting=cameraTag, decode=bt601 full range"), tagged)
        XCTAssertEqual(roundVideoFourCharCode(self.videoRange), "420v")
    }
}
