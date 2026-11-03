import Foundation
import UIKit

// A-8 (iPadOS 27 audit, 2026-11-03): orientation locks on iPad. On iOS 27 an app's supported orientations are "a
// preference … ignored when your app is running in a resizable environment" (WWDC26-278). iOS 26 adds
// `prefersInterfaceOrientationLocked`, but the SDK header (UIViewController.h) says the system considers it only when
// the scene is centred, takes the whole screen and is not covered by another scene: full screen, not a resizable
// Stage Manager or windowed-apps window. There, nothing an app sets keeps the orientation (review I1, 2026-11-03);
// rotation while recording in such a window is P-12's (the recording screens must lay out in any shape).

/// Whether the window's root controller asks the system to keep the current orientation: on a tablet, only while the
/// visible screens allow one axis, portrait or landscape (`lockOrientation` produces the current orientation alone;
/// an orientation-restricted screen one axis). A mask with both axes is not a lock, in particular a compact
/// controller's default `.allButUpsideDown`. Never on a phone.
public func windowPrefersInterfaceOrientationLocked(deviceType: DeviceType, supportedOrientations: UIInterfaceOrientationMask) -> Bool {
    guard case .tablet = deviceType else {
        return false
    }
    if supportedOrientations.isEmpty {
        return false
    }
    let portraitAxis: UIInterfaceOrientationMask = [.portrait, .portraitUpsideDown]
    return portraitAxis.isSuperset(of: supportedOrientations) || UIInterfaceOrientationMask.landscape.isSuperset(of: supportedOrientations)
}

/// The interface orientation of a window scene: on a tablet with iOS 26, the scene's effective geometry
/// (`effectiveGeometry.interfaceOrientation`), which follows a resizable window; else the deprecated
/// `UIWindowScene.interfaceOrientation` upstream reads. Both agree outside resizable windows.
public func sceneInterfaceOrientation(deviceType: DeviceType, legacy: UIInterfaceOrientation, effectiveGeometry: UIInterfaceOrientation?) -> UIInterfaceOrientation {
    if case .tablet = deviceType, let effectiveGeometry, effectiveGeometry != .unknown {
        return effectiveGeometry
    }
    return legacy
}

public extension UIWindowScene {
    /// `sceneInterfaceOrientation` for this scene. `isTablet` defaults to the device's idiom.
    func nanogramInterfaceOrientation(isTablet: Bool = UIDevice.current.userInterfaceIdiom == .pad) -> UIInterfaceOrientation {
        var effective: UIInterfaceOrientation?
        if #available(iOS 26.0, *) {
            effective = self.effectiveGeometry.interfaceOrientation
        }
        let legacy = self.interfaceOrientation
        return sceneInterfaceOrientation(deviceType: isTablet ? .tablet : .phone, legacy: legacy, effectiveGeometry: effective)
    }

}
