import Foundation
import UIKit
import UIKitRuntimeUtils

public enum Keyboard {
    /// Commits the keyboard's pending autocorrection (the system corrects the last word when the caret moves). The
    /// commit costs up to ~210 ms, so it runs only when `needsAutocorrectionCommit` says there is something to commit.
    public static func applyAutocorrection(textView: UITextView) {
        guard needsAutocorrectionCommit(text: textView.text ?? "", selection: textView.selectedRange, hasMarkedText: textView.markedTextRange != nil) else {
            return
        }
        applyKeyboardAutocorrection(textView)
    }
}

/// Whether the keyboard may still change the text before it is read: there is marked (uncommitted) text, or the caret
/// follows a non-whitespace character and the word before it contains a letter, so it could be autocorrected. A range
/// selection, a caret at the start or after whitespace, and a last word of digits and punctuation have nothing pending.
public func needsAutocorrectionCommit(text: String, selection: NSRange, hasMarkedText: Bool) -> Bool {
    if hasMarkedText {
        return true
    }
    let nsText = text as NSString
    guard selection.location != NSNotFound, selection.length == 0, selection.location > 0, selection.location <= nsText.length else {
        return false
    }
    let beforeCaret = nsText.substring(to: selection.location)
    guard let last = beforeCaret.last, !last.isWhitespace, !last.isNewline else {
        return false
    }
    var hasLetter = false
    for character in beforeCaret.reversed() {
        if character.isWhitespace || character.isNewline {
            break
        }
        if character.isLetter {
            hasLetter = true
            break
        }
    }
    return hasLetter
}
