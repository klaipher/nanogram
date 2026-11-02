import XCTest
import UIKit
import MozjpegBinding

/// `decompressImage` decodes JPEGs that arrive from chats (tiny thumbnails) and the media cache. A failed decode must
/// give nil, so the caller falls back to UIImage(data:), and never an image of whatever the buffer held.
final class JpegDecodeHardeningTests: XCTestCase {
    /// A 16x16 CMYK JPEG: the decoder cannot convert CMYK to RGB, so its output buffer is never written.
    private let cmykJPEG = "/9j/7gAOQWRvYmUAZAAAAAAA/9sAQwAGBgYGBwYHCAgHCgsKCwoPDgwMDg8WEBEQERAWIhUZFRUZFSIeJB4cHiQeNiomJio2PjQyND5MRERMX1pffHyn/8IAFAgAEAAQBEMRAE0RAFkRAEsRAP/EABUAAQEAAAAAAAAAAAAAAAAAAAgH/9oADgRDAE0AWQBLAAAAAI/JJVL1Wq1UqyoVCqVFWq1Uq//EABYQAAMAAAAAAAAAAAAAAAAAAAAEQf/aAAgBQwABCAJOCcE4Jw//xAAWEAADAAAAAAAAAAAAAAAAAAAABEH/2gAIAU0AAQgCTgnBOCcP/8QAFhAAAwAAAAAAAAAAAAAAAAAAAARB/9oACAFZAAEIAk4JwTgnD//EABYQAAMAAAAAAAAAAAAAAAAAAAAEQf/aAAgBSwABCAJOCcE4Jw//xAAUEAEAAAAAAAAAAAAAAAAAAAAg/9oACAFDAAk/Ah//xAAUEAEAAAAAAAAAAAAAAAAAAAAg/9oACAFNAAk/Ah//xAAUEAEAAAAAAAAAAAAAAAAAAAAg/9oACAFZAAk/Ah//xAAUEAEAAAAAAAAAAAAAAAAAAAAg/9oACAFLAAk/Ah//xAAUEAEAAAAAAAAAAAAAAAAAAAAg/9oACAFDAAE/IQAf/8QAFBABAAAAAAAAAAAAAAAAAAAAIP/aAAgBTQABPyEAH//EABQQAQAAAAAAAAAAAAAAAAAAACD/2gAIAVkAAT8hAB//xAAUEAEAAAAAAAAAAAAAAAAAAAAg/9oACAFLAAE/IQAf/8QAFBABAAAAAAAAAAAAAAAAAAAAIP/aAAgBQwABPxAVX//EABQQAQAAAAAAAAAAAAAAAAAAACD/2gAIAU0AAT8QFV//xAAUEAEAAAAAAAAAAAAAAAAAAAAg/9oACAFZAAE/EBVf/8QAFBABAAAAAAAAAAAAAAAAAAAAIP/aAAgBSwABPxAVX//Z"

    func testUndecodableColorSpaceGivesNil() {
        XCTAssertNil(decompressImage(Data(base64Encoded: self.cmykJPEG)!))
    }

    func testTruncatedHeaderGivesNil() {
        let data = Data(base64Encoded: self.cmykJPEG)!
        XCTAssertNil(decompressImage(data.prefix(20)))
        XCTAssertNil(decompressImage(Data()))
    }

    /// A header that claims more pixels than the decode buffer can hold is refused before allocating it (the buffer
    /// size was computed in 32-bit int arithmetic, which overflows at 65500 x 65500).
    func testHugeDimensionsGiveNil() {
        var data = Data(base64Encoded: self.cmykJPEG)!
        // A start-of-frame marker (FF C0, C1 or C2), then length (2), precision (1), height (2), width (2).
        guard let sof = [0xc0, 0xc1, 0xc2].lazy.compactMap({ data.firstRange(of: Data([0xff, $0])) }).first else {
            XCTFail("no start-of-frame marker")
            return
        }
        let at = sof.lowerBound + 5
        data[at] = 0xff
        data[at + 1] = 0xdc
        data[at + 2] = 0xff
        data[at + 3] = 0xdc
        XCTAssertNil(decompressImage(data))
    }
}
