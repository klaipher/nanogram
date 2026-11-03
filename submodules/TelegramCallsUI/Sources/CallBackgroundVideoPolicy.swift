import Foundation
import UIKit

public enum CallBackgroundVideoPolicy {
    /// Incoming 1:1 video can be dropped before it reaches the app only when nothing can show it: the app is in the
    /// background (not merely inactive, which still shows the call) and Picture in Picture is not on screen.
    public static func shouldDropIncomingVideo(applicationState: UIApplication.State, isPictureInPictureActive: Bool, isEnabled: Bool) -> Bool {
        return isEnabled && applicationState == .background && !isPictureInPictureActive
    }
}
