import XCTest
import UIKit
import QuartzCore
@testable import TextFormat

/// `refreshChatTextInputAttributes` runs on every keystroke. With any emoji in the draft the text storage keeps the
/// requested font under `NSOriginalFont` and draws the emoji with Apple Color Emoji, so the rebuilt string never
/// compared equal and the whole draft was stripped of 11 attributes and decorated again, a no-op costing 1.7-7.2 ms
/// at 1k-4k characters (plus a full layout invalidation).
final class RefreshInputAttributesNoOpTests: XCTestCase {
    private final class EditCounter: NSObject, NSTextStorageDelegate {
        var attributeEdits = 0
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
            if editedMask.contains(.editedAttributes) {
                self.attributeEdits += 1
            }
        }
    }

    private func makeText(_ length: Int, emojiEvery: Int?) -> String {
        let words = ["hello", "привіт", "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "telegram", "повідомлення"]
        let emojis = ["😀", "👍🏽", "❤️", "🎉", "🇺🇦", "👨‍👩‍👧"]
        var text = ""
        var index = 0
        while (text as NSString).length < length {
            text += words[index % words.count]
            if let emojiEvery, index % emojiEvery == emojiEvery - 1 {
                text += " " + emojis[index % emojis.count]
            }
            text += index % 12 == 11 ? "\n" : " "
            index += 1
        }
        return text
    }

    private func refresh(_ textView: UITextView) {
        refreshChatTextInputAttributes(context: NSObject(), textView: textView, primaryTextColor: .black, accentTextColor: .blue, baseFontSize: 17.0, spoilersRevealed: false, availableEmojis: Set(), emojiViewProvider: nil, makeCollapsedQuoteAttachment: nil)
    }

    // A draft with emoji, bold, a text link and a spoiler, decorated once (as after the first keystroke).
    // TextKit 1 with a concrete NSTextStorage, as the composer (ChatInputTextView) has.
    private func decoratedTextView(_ text: String) -> UITextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 320.0, height: 100000.0))
        layoutManager.addTextContainer(container)
        let textView = UITextView(frame: CGRect(x: 0.0, y: 0.0, width: 320.0, height: 400.0), textContainer: container)
        // What typing produces: the composer's typing attributes (refreshChatTextInputTypingAttributes).
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.baseWritingDirection = .natural
        let string = NSMutableAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 17.0), .foregroundColor: UIColor.black, .paragraphStyle: paragraphStyle])
        if string.length > 40 {
            string.addAttribute(ChatTextInputAttributes.bold, value: true as NSNumber, range: NSRange(location: 5, length: 10))
            string.addAttribute(ChatTextInputAttributes.textUrl, value: ChatTextInputTextUrlAttribute(url: "https://telegram.org"), range: NSRange(location: 20, length: 6))
            string.addAttribute(ChatTextInputAttributes.spoiler, value: true as NSNumber, range: NSRange(location: 30, length: 5))
        }
        textView.attributedText = string
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        self.refresh(textView)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        return textView
    }

    // The first character whose attributes differ between `lhs` and `rhs`, for failure messages.
    private func firstDifference(_ lhs: NSAttributedString, _ rhs: NSAttributedString) -> String {
        if lhs.string != rhs.string {
            return "strings differ"
        }
        for index in 0 ..< lhs.length {
            let lhsAttributes = lhs.attributes(at: index, effectiveRange: nil)
            let rhsAttributes = rhs.attributes(at: index, effectiveRange: nil)
            if !(lhsAttributes as NSDictionary).isEqual(to: rhsAttributes) {
                var keys: [String] = []
                for key in Set(lhsAttributes.keys).union(rhsAttributes.keys) {
                    let lhsValue = lhsAttributes[key] as? NSObject
                    let rhsValue = rhsAttributes[key] as? NSObject
                    if lhsValue != rhsValue {
                        keys.append("\(key.rawValue): \(String(describing: lhsValue)) vs \(String(describing: rhsValue))")
                    }
                }
                return "at \(index): " + keys.joined(separator: "; ")
            }
        }
        return "equal"
    }

    func testRefreshOfAnUnchangedDraftWithEmojiEditsNothing() {
        for text in [self.makeText(200, emojiEvery: 6), "😀", "a😀b", self.makeText(1000, emojiEvery: 3)] {
            let textView = self.decoratedTextView(text)
            let before = NSAttributedString(attributedString: textView.textStorage)
            XCTAssertTrue(attributedStringContainsOriginalFont(before), "the storage substitutes fonts for emoji")
            let counter = EditCounter()
            textView.textStorage.delegate = counter
            self.refresh(textView)
            XCTAssertEqual(counter.attributeEdits, 0, text.prefix(20).debugDescription)
            if counter.attributeEdits != 0 {
                let rebuilt = textAttributedStringForStateText(context: NSObject(), stateText: stateAttributedStringForText(before), fontSize: 17.0, textColor: .black, accentTextColor: .blue, writingDirection: (before.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.baseWritingDirection, spoilersRevealed: false, availableEmojis: Set(), emojiViewProvider: nil, makeCollapsedQuoteAttachment: nil)
                print("DIFF storage vs rebuilt: \(self.firstDifference(attributedStringRevertingFontSubstitution(before) ?? before, rebuilt))")
            }
            XCTAssertTrue(textView.textStorage.isEqual(to: before))
        }
    }

    // Same storage as the full strip-and-redecorate produced: refresh a copy whose fonts were reset, which has to
    // take the full path, and compare.
    func testDecorationResultUnchanged() {
        let text = self.makeText(600, emojiEvery: 5)
        let textView = self.decoratedTextView(text)
        self.refresh(textView)

        let forced = self.decoratedTextView(text)
        forced.textStorage.addAttribute(.foregroundColor, value: UIColor.red, range: NSRange(location: 0, length: 3))
        self.refresh(forced)
        // Font substitution in the storage is lazy; settle both before comparing.
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        forced.layoutManager.ensureLayout(for: forced.textContainer)
        // Compared per character: the storage fixes attributes lazily on access, so comparing the two storages
        // directly can see one range fixed in one and not yet in the other.
        XCTAssertEqual(self.firstDifference(forced.textStorage, textView.textStorage), "equal")
    }

    func testRealDifferencesAreStillFixed() {
        let textView = self.decoratedTextView(self.makeText(300, emojiEvery: 4))
        textView.textStorage.addAttribute(.foregroundColor, value: UIColor.red, range: NSRange(location: 0, length: 3))
        self.refresh(textView)
        XCTAssertEqual(textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, UIColor.black)
    }

    // Benchmark: one refresh of an unchanged draft (what each keystroke pays).
    func testBenchmarkRefreshPerKeystroke() {
        var lines: [String] = []
        for (label, length, emojiEvery) in [("short", 30, nil as Int?), ("1k", 1000, nil), ("4k", 4000, nil), ("1k+emoji", 1000, 6), ("4k+emoji", 4000, 6)] {
            let textView = self.decoratedTextView(self.makeText(length, emojiEvery: emojiEvery))
            var best = Double.infinity
            for _ in 0 ..< 5 {
                let start = CACurrentMediaTime()
                for _ in 0 ..< 5 {
                    self.refresh(textView)
                }
                best = min(best, (CACurrentMediaTime() - start) / 5.0)
            }
            lines.append("\(label) \(String(format: "%.0f", best * 1_000_000.0)) us")
        }
        print("BENCH refreshChatTextInputAttributes per keystroke: " + lines.joined(separator: ", "))
    }
}
