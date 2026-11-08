import Foundation

/// Debug Settings ▸ "Keyboard: leave the keyboard window alone (A/B)" (off by default). Since iOS 17 the iPhone keyboard runs
/// in its own process (WWDC23 "Keep up with the keyboard"), yet the 202611081037 frame hitch log showed the keyboard
/// layout being built (`UIKeyboardLayoutStar createLayoutFromName`) and keys drawn (`UIKBKeyView displayLayer`) on our main
/// thread. Telegram reads `keyboardSceneDelegate.keyboardWindow` on every keyboard notification and layout (to move the
/// keyboard during interactive dismissal and to place overlays above it); the A/B checks whether that read keeps the
/// keyboard in our process. On: the app never asks for the keyboard window, so the keyboard does not follow the finger
/// during a swipe-down dismissal and overlays are not lifted above it. Set by the app on the main thread.
public enum KeyboardWindowAccess {
    public static var isDisabled: Bool = false
}
