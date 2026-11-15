import XCTest
import CoreImage
@testable import ImageObjectSeparation

final class SharedStickerCIContextTests: XCTestCase {
    func testContextIsReusedAcrossCalls() {
        XCTAssertTrue(SharedStickerCIContext.context === SharedStickerCIContext.context)
    }

    func testContextRendersAnImage() throws {
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let rendered = SharedStickerCIContext.context.createCGImage(image, from: image.extent)
        #if targetEnvironment(simulator)
        // The shared context is a default (GPU) Core Image context. The headless Bazel test simulator (iOS 27.2) gives it
        // no renderer and createCGImage returns nil there (2026-11-15); on a device the same context renders.
        if rendered == nil {
            throw XCTSkip("Core Image's GPU renderer is unavailable in this headless simulator")
        }
        #endif
        XCTAssertNotNil(rendered)
    }
}
