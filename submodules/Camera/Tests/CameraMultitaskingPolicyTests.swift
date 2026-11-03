import XCTest
import AVFoundation
@testable import CameraMultitaskingPolicy

/// Pins A-4 of the iPadOS 27 audit: on an iPad the in-app cameras keep running in Split View, Slide Over and Stage
/// Manager (`AVCaptureSession.isMultitaskingCameraAccessEnabled`), as the call camera in tgcalls already does. Phones
/// keep the system default, as upstream.
final class CameraMultitaskingPolicyTests: XCTestCase {
    func testOnlyASupportedTabletEnablesMultitaskingAccess() {
        XCTAssertTrue(CameraMultitaskingAccess.isEnabled(isTablet: true, isSupported: true))
        XCTAssertFalse(CameraMultitaskingAccess.isEnabled(isTablet: true, isSupported: false))
        XCTAssertFalse(CameraMultitaskingAccess.isEnabled(isTablet: false, isSupported: true))
        XCTAssertFalse(CameraMultitaskingAccess.isEnabled(isTablet: false, isSupported: false))
    }

    /// Applying the policy to a real session never sets the property where the session does not support it (setting it
    /// there raises), and never touches a phone's session.
    func testApplyingThePolicyIsSafeOnAnySession() throws {
        guard #available(iOS 16.0, *) else {
            throw XCTSkip("multitasking camera access needs iOS 16")
        }
        for isTablet in [false, true] {
            let session = AVCaptureSession()
            CameraMultitaskingAccess.apply(to: session, isTablet: isTablet)
            XCTAssertEqual(session.isMultitaskingCameraAccessEnabled, isTablet && session.isMultitaskingCameraAccessSupported, "isTablet=\(isTablet)")
        }
    }
}
