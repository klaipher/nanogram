import UIKit

// TEMPORARY (2026-11-03): one line per keyboard notification the window acts on, to confirm on the owner's iPad
// where a phantom ~80pt "keyboard" comes from. Remove this file and the two `#if DEBUG // TEMP iPad keyboard log`
// blocks in WindowContent.swift once confirmed. In the device console filter on "[iPadKeyboard]".
#if DEBUG
func debugLogWindowKeyboard(event: String, endFrame: CGRect, windowSize: CGSize, isTablet: Bool, isWindowed: Bool?, decision: WindowKeyboardNotificationDecision, inputHeight: CGFloat) {
    let windowed = isWindowed.flatMap { $0 ? "yes" : "no" } ?? "n/a"
    NSLog("[iPadKeyboard] %@ endFrame=%@ window=%@ screen=%@ tablet=%@ windowed=%@ decision=%@ inputHeight=%.1f", event, NSCoder.string(for: endFrame), NSCoder.string(for: windowSize), NSCoder.string(for: UIScreen.main.bounds.size), isTablet ? "yes" : "no", windowed, "\(decision)", inputHeight)
}
#endif
