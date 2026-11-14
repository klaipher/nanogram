import XCTest
import UIKit
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

final class UniversalSoftwareVideoSourceFirstFrameTests: XCTestCase {
    private func makeImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    func testWaitingForDataKeepsWaiting() {
        guard case .pending = UniversalSoftwareVideoSourceTakeFrameResult.waitingForData.firstFrame(compressionQuality: 0.6) else {
            return XCTFail("waitingForData must stay pending")
        }
    }

    func testNilImageCompletesAsFailed() {
        guard case .failed = UniversalSoftwareVideoSourceTakeFrameResult.image(nil).firstFrame(compressionQuality: 0.6) else {
            return XCTFail("a failed decode must complete the request")
        }
    }

    func testImageThatCannotBeEncodedCompletesAsFailed() {
        guard case .failed = UniversalSoftwareVideoSourceTakeFrameResult.image(UIImage()).firstFrame(compressionQuality: 0.6) else {
            return XCTFail("an image without bitmap data must complete the request")
        }
    }

    func testImageProducesJPEGData() {
        guard case let .jpeg(data) = UniversalSoftwareVideoSourceTakeFrameResult.image(makeImage()).firstFrame(compressionQuality: 0.6) else {
            return XCTFail("a decoded image must produce JPEG data")
        }
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
    }
}
