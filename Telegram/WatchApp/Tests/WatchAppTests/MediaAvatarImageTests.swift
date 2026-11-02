import XCTest
import UIKit
@testable import tgwatch_Watch_App

/// Avatars read and decoded their file inside `body`, so every chat-list update re-read every
/// visible avatar from flash. They now go through `MediaImageCache`, at display size.
final class MediaAvatarImageTests: XCTestCase {
    private var path: String!

    override func setUpWithError() throws {
        MediaImageCache.removeAll()
        // TDLib's small chat photo is 160x160.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 160, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        let jpeg = try XCTUnwrap(UIImage(cgImage: try XCTUnwrap(context.makeImage())).jpegData(compressionQuality: 0.9))
        path = NSTemporaryDirectory() + "avatar-test-\(UUID().uuidString).jpg"
        try jpeg.write(to: URL(fileURLWithPath: path))
    }

    override func tearDown() {
        MediaImageCache.removeAll()
        if let path { try? FileManager.default.removeItem(atPath: path) }
    }

    func testPhotoIsDecodedOnceAtDisplaySize() throws {
        let first = try XCTUnwrap(AvatarImages.photo(path: path, pointSize: 36, scale: 2))
        let second = try XCTUnwrap(AvatarImages.photo(path: path, pointSize: 36, scale: 2))
        XCTAssertTrue(first === second, "decoded again")
        XCTAssertEqual(first.cgImage?.width, 72)
        XCTAssertEqual(first.cgImage?.height, 72)
    }

    func testMissingPhotoFileGivesNil() {
        XCTAssertNil(AvatarImages.photo(path: path + ".missing", pointSize: 36, scale: 2))
    }

    func testMinithumbnailIsDecodedOncePerFile() throws {
        let mini = try XCTUnwrap(UIImage(contentsOfFile: path)?.jpegData(compressionQuality: 0.5))
        let first = try XCTUnwrap(AvatarImages.minithumbnail(mini, photoFileId: 5))
        let second = try XCTUnwrap(AvatarImages.minithumbnail(mini, photoFileId: 5))
        XCTAssertTrue(first === second, "decoded again")
        let other = try XCTUnwrap(AvatarImages.minithumbnail(mini, photoFileId: 6))
        XCTAssertFalse(first === other)
    }
}
