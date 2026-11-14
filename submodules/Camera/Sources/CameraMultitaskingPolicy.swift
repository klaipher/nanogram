import Foundation
import UIKit
import AVFoundation

/// iPad (audit A-4): whether an in-app camera keeps running while the app shares the screen (Split View, Slide Over,
/// Stage Manager) instead of being interrupted with `.videoDeviceNotAvailableWithMultipleForegroundApps`. The call
/// camera in tgcalls already does this; the story/attachment camera (CameraNeo), the round-video cameras (CameraLegacy,
/// `TGVideoCameraPipeline`) and the legacy attachment camera (`PGCameraCaptureSession`) did not. The app's `voip`
/// background mode qualifies it; no entitlement. Phones keep the system default, as upstream.
public enum CameraMultitaskingAccess {
    public static func isEnabled(isTablet: Bool, isSupported: Bool) -> Bool {
        return isTablet && isSupported
    }

    /// Applies `isEnabled` to a capture session; setting the property where it is not supported would raise.
    /// `isTablet` defaults to the device's idiom.
    public static func apply(to session: AVCaptureSession, isTablet: Bool = UIDevice.current.userInterfaceIdiom == .pad) {
        if CameraMultitaskingAccess.isEnabled(isTablet: isTablet, isSupported: session.isMultitaskingCameraAccessSupported), !session.isMultitaskingCameraAccessEnabled {
            session.isMultitaskingCameraAccessEnabled = true
        }
    }
}
