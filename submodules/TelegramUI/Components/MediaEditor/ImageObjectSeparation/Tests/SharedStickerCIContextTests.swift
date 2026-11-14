import XCTest
import CoreImage
@testable import ImageObjectSeparation

final class SharedStickerCIContextTests: XCTestCase {
    func testContextIsReusedAcrossCalls() {
        XCTAssertTrue(SharedStickerCIContext.context === SharedStickerCIContext.context)
    }

    func testContextRendersAnImage() {
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertNotNil(SharedStickerCIContext.context.createCGImage(image, from: image.extent))
    }
}
