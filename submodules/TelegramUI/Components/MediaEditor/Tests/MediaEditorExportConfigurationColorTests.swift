import XCTest
import AVFoundation
import TelegramCore
@testable import MediaEditor

/// `MediaEditorExportColorTests` checks what the tagged settings decode to; this pins that the
/// configuration every export path asks for (stories, video messages, avatars, edited sends)
/// actually carries the tags, and that VP9 stickers (FFmpeg writer) stay untagged.
final class MediaEditorExportConfigurationColorTests: XCTestCase {
    private func values(dimensions: PixelDimensions, qualityPreset: MediaQualityPreset?) -> MediaEditorValues {
        return MediaEditorValues(
            peerId: EnginePeer.Id(0),
            originalDimensions: dimensions,
            cropOffset: .zero,
            cropRect: nil,
            cropScale: 1.0,
            cropRotation: 0.0,
            cropMirroring: false,
            cropOrientation: nil,
            cropPerspective: .zero,
            gradientColors: nil,
            videoTrimRange: nil,
            videoBounce: false,
            videoIsMuted: false,
            videoIsFullHd: false,
            videoIsMirrored: false,
            videoVolume: 1.0,
            additionalVideoPath: nil,
            additionalVideoIsDual: false,
            additionalVideoMirroringChanges: [],
            additionalVideoPosition: nil,
            additionalVideoScale: nil,
            additionalVideoRotation: nil,
            additionalVideoPositionChanges: [],
            additionalVideoTrimRange: nil,
            additionalVideoOffset: nil,
            additionalVideoVolume: nil,
            collage: [],
            nightTheme: false,
            drawing: nil,
            maskDrawing: nil,
            entities: [],
            toolValues: [:],
            audioTrack: nil,
            audioTrackTrimRange: nil,
            audioTrackOffset: nil,
            audioTrackVolume: nil,
            audioTrackSamples: nil,
            collageTrackSamples: nil,
            coverImageTimestamp: nil,
            coverDimensions: nil,
            qualityPreset: qualityPreset
        )
    }

    private func assertTaggedBT709(_ configuration: MediaEditorVideoExport.Configuration, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let colorProperties = configuration.videoSettings[AVVideoColorPropertiesKey] as? [String: String]
        XCTAssertEqual(colorProperties?[AVVideoColorPrimariesKey], AVVideoColorPrimaries_ITU_R_709_2, message, file: file, line: line)
        XCTAssertEqual(colorProperties?[AVVideoTransferFunctionKey], AVVideoTransferFunction_ITU_R_709_2, message, file: file, line: line)
        XCTAssertEqual(colorProperties?[AVVideoYCbCrMatrixKey], AVVideoYCbCrMatrix_ITU_R_709_2, message, file: file, line: line)
    }

    func testEveryH264AndHEVCExportIsTaggedBT709() {
        let source = PixelDimensions(width: 1080, height: 1920)
        self.assertTaggedBT709(recommendedVideoExportConfiguration(values: self.values(dimensions: source, qualityPreset: nil), duration: 10.0, frameRate: 30.0), "story")
        self.assertTaggedBT709(recommendedVideoExportConfiguration(values: self.values(dimensions: source, qualityPreset: .videoMessage), duration: 10.0, frameRate: 30.0), "video message")
        self.assertTaggedBT709(recommendedVideoExportConfiguration(values: self.values(dimensions: source, qualityPreset: .compressedMedium), duration: 10.0, frameRate: 30.0), "edited send")
        self.assertTaggedBT709(recommendedVideoExportConfiguration(values: self.values(dimensions: source, qualityPreset: nil), duration: 5.0, frameRate: 30.0, isAvatar: true), "avatar")
        self.assertTaggedBT709(recommendedVideoExportConfiguration(values: self.values(dimensions: source, qualityPreset: nil), duration: 0.0, image: true, frameRate: 30.0), "image to video")
    }

    func testVP9StickerExportStaysUntagged() {
        let configuration = recommendedVideoExportConfiguration(values: self.values(dimensions: PixelDimensions(width: 512, height: 512), qualityPreset: nil), duration: 3.0, frameRate: 30.0, isSticker: true)
        XCTAssertEqual(configuration.videoSettings[AVVideoCodecKey] as? String, "VP9")
        XCTAssertNil(configuration.videoSettings[AVVideoColorPropertiesKey])
    }
}
