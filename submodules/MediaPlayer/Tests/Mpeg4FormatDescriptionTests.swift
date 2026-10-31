import XCTest
import CoreMedia
import VideoToolbox
import UniversalMediaPlayer

// MPEG-4 Part 2 videos (some GIFs are encoded this way) are passed straight to Apple's decoder.
// FFmpeg's extradata for them is the raw VOS/VOL header, while the format description's esds atom
// must hold a full ES descriptor. With the raw bytes the decoder could not be created (-12909),
// so such a GIF showed its first frame and never played.
final class Mpeg4FormatDescriptionTests: XCTestCase {
    // The VOS/VOL header of a 357x372 GIF that stayed frozen in a chat (FFmpeg Lavc58 encoder).
    private let rawCodecData = Data([
        0x00, 0x00, 0x01, 0xb0, 0x01, 0x00, 0x00, 0x01, 0xb5, 0x89, 0x13, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x01, 0x20, 0x00, 0xc4, 0x8d, 0x88, 0x00, 0xcd, 0x0b, 0x2c, 0x2e, 0x94, 0x43, 0x00, 0x00,
        0x01, 0xb2, 0x4c, 0x61, 0x76, 0x63, 0x35, 0x38, 0x2e, 0x35, 0x34, 0x2e, 0x31, 0x30, 0x30
    ])

    func testDecoderAcceptsFormatBuiltFromRawCodecData() throws {
        let format = try XCTUnwrap(FFMpegMediaFrameSourceContextHelpers.createFormatDescriptionFromMpeg4CodecData(UInt32(kCMVideoCodecType_MPEG4Video), 357, 372, self.rawCodecData))

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        XCTAssertEqual(status, noErr)
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
