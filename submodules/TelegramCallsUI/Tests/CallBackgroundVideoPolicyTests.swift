import Foundation
import UIKit
import XCTest
@testable import TelegramCallsUI

/// Incoming 1:1 video is dropped locally only when nothing can show it: the app is in the background and Picture in
/// Picture is not on screen. An inactive app (the notification shade, the app switcher) still shows the call.
final class CallBackgroundVideoPolicyTests: XCTestCase {
    func testBackgroundWithoutPictureInPictureDrops() {
        XCTAssertTrue(CallBackgroundVideoPolicy.shouldDropIncomingVideo(applicationState: .background, isPictureInPictureActive: false, isEnabled: true))
    }

    func testPictureInPictureKeepsTheVideo() {
        XCTAssertFalse(CallBackgroundVideoPolicy.shouldDropIncomingVideo(applicationState: .background, isPictureInPictureActive: true, isEnabled: true))
    }

    func testActiveAndInactiveKeepTheVideo() {
        XCTAssertFalse(CallBackgroundVideoPolicy.shouldDropIncomingVideo(applicationState: .active, isPictureInPictureActive: false, isEnabled: true))
        XCTAssertFalse(CallBackgroundVideoPolicy.shouldDropIncomingVideo(applicationState: .inactive, isPictureInPictureActive: false, isEnabled: true))
    }

    func testSwitchOffNeverDrops() {
        XCTAssertFalse(CallBackgroundVideoPolicy.shouldDropIncomingVideo(applicationState: .background, isPictureInPictureActive: false, isEnabled: false))
    }
}
