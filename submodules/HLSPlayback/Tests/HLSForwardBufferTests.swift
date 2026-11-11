import XCTest
@testable import HLSPlayback

final class HLSForwardBufferTests: XCTestCase {
    func testMutedInlinePlaybackBuffersTheShortWindow() {
        XCTAssertEqual(hlsForwardBufferSeconds(isMuted: true, isInline: true), 15.0)
    }
    
    func testSoundGalleryAndFullscreenBufferTheFullWindow() {
        XCTAssertEqual(hlsForwardBufferSeconds(isMuted: false, isInline: true), 60.0)
        XCTAssertEqual(hlsForwardBufferSeconds(isMuted: true, isInline: false), 60.0)
        XCTAssertEqual(hlsForwardBufferSeconds(isMuted: false, isInline: false), 60.0)
    }
    
    func testTheFullWindowIsTheControllersDefault() {
        XCTAssertEqual(hlsForwardBufferSeconds(isMuted: false, isInline: false), HLSPlaybackController.Configuration().maxBufferAhead)
    }
}
