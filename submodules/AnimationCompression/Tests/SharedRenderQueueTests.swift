import XCTest
import Metal
@testable import AnimationCompression

final class SharedRenderQueueTests: XCTestCase {
    func testRenderersShareTheContextRenderQueue() throws {
        guard let context = AnimationCompressor.SharedContext.sharedIfAvailable else {
            throw XCTSkip("No Metal device or shader bundle in this test process")
        }
        let queue = context.renderCommandQueue
        XCTAssertNotNil(CompressedImageRenderer(sharedContext: context))
        XCTAssertNotNil(CompressedImageRenderer(sharedContext: context))
        XCTAssertTrue(context.renderCommandQueue === queue)
        XCTAssertTrue(context.device === queue.device)
    }
}
