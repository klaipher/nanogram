import Foundation
import UIKit

// A-8 (iPadOS 27 audit, 2026-11-03): orientation locks in resizable windows. On iOS 27 an app's supported orientations
// are "a preference … ignored when your app is running in a resizable environment" (WWDC26-278), so a screen that locks
// rotation by narrowing the mask (recording a round video or a voice message, `ViewController.lockOrientation`) is not
// locked in Stage Manager or a windowed iPad app. iOS 26 adds `prefersInterfaceOrientationLocked`, which is honoured
// there.

/// Whether the window's root controller asks the system to keep the current orientation: on a tablet, whenever the
/// orientations the visible screens allow are narrower than the window's default (`defaultOrientations`, all four on
/// an iPad), which is what every lock and every orientation-restricted screen produces. Never on a phone.
public func windowPrefersInterfaceOrientationLocked(deviceType: DeviceType, supportedOrientations: UIInterfaceOrientationMask, defaultOrientations: UIInterfaceOrientationMask) -> Bool {
    guard case .tablet = deviceType else {
        return false
    }
    return supportedOrientations != defaultOrientations && defaultOrientations.isSuperset(of: supportedOrientations)
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
