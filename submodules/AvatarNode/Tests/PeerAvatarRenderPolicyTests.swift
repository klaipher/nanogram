import XCTest
import UIKit
@testable import AvatarNode

/// Which thread decodes an avatar that is not in the render cache, and when the cache alone answers.
final class PeerAvatarRenderPolicyTests: XCTestCase {
    func testAsynchronousRequestsNeverDecodeOnTheCallingThread() {
        for avoid in [false, true] {
            for type in [nil, PeerAvatarImageType.blurred, .complete] {
                XCTAssertFalse(peerAvatarRendersOnCallingThread(synchronousLoad: false, avoidMainThreadDecode: avoid, dataType: type))
            }
        }
    }

    func testSynchronousRequestsKeepDecodingInlineByDefault() {
        for type in [nil, PeerAvatarImageType.blurred, .complete] {
            XCTAssertTrue(peerAvatarRendersOnCallingThread(synchronousLoad: true, avoidMainThreadDecode: false, dataType: type))
        }
    }

    func testAvoidingMainThreadDecodeMovesOnlyCompletePhotosOff() {
        XCTAssertFalse(peerAvatarRendersOnCallingThread(synchronousLoad: true, avoidMainThreadDecode: true, dataType: .complete))
        XCTAssertTrue(peerAvatarRendersOnCallingThread(synchronousLoad: true, avoidMainThreadDecode: true, dataType: .blurred))
        XCTAssertTrue(peerAvatarRendersOnCallingThread(synchronousLoad: true, avoidMainThreadDecode: true, dataType: nil))
    }

    func testCachedLookupFindsWhatARenderStoredAndNothingElse() {
        let cache = PeerAvatarImageCache(totalCostLimit: 4 * 1024 * 1024)
        let size = CGSize(width: 60.0, height: 60.0)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64.0, height: 64.0))
        let jpeg = renderer.jpegData(withCompressionQuality: 0.8) { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let data: (Data, PeerAvatarImageType)? = (jpeg, .complete)
        func lookup(_ resourceId: String?, _ data: (Data, PeerAvatarImageType)?, clip: AvatarNodeClipStyle = .round, unrounded: Bool = false) -> (UIImage, UIImage)? {
            return peerAvatarCachedImages(resourceId: resourceId, data: data, displayDimensions: size, clipStyle: clip, blurred: false, inset: 0.0, provideUnrounded: unrounded, cutoutRect: nil, cache: cache)
        }
        XCTAssertNil(lookup("a", data), "nothing rendered yet")
        let rendered = peerAvatarRenderedImages(resourceId: "a", data: data, displayDimensions: size, clipStyle: .round, blurred: false, inset: 0.0, emptyColor: nil, provideUnrounded: false, cutoutRect: nil, cache: cache)
        XCTAssertNotNil(rendered)
        XCTAssertTrue(lookup("a", data)?.0 === rendered?.0)
        XCTAssertNil(lookup("b", data), "other resource")
        XCTAssertNil(lookup("a", data, clip: .roundedRect), "other clip style")
        XCTAssertNil(lookup("a", data, unrounded: true), "other unrounded flag")
        XCTAssertNil(lookup(nil, data), "no resource id")
        XCTAssertNil(lookup("a", (jpeg, .blurred)), "previews are never served from the cache")
        XCTAssertNil(lookup("a", nil))
    }
}
