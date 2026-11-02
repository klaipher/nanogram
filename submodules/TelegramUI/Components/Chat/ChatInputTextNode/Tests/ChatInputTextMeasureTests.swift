import XCTest
import UIKit
import QuartzCore
@testable import ChatInputTextNode

/// The composer measures its height on a second TextKit stack after every keystroke. It used to set the whole
/// text again and relayout it all (3-8 ms per keystroke at 4k characters); it now replaces only the edited range.
final class ChatInputTextMeasureTests: XCTestCase {
    private let width: CGFloat = 300.0
    private let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17.0), .foregroundColor: UIColor.black]

    private func makeText(_ length: Int, emojiEvery: Int?, newlineEvery: Int? = 12) -> String {
        let words = ["hello", "привіт", "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "telegram", "повідомлення", "and", "then", "some"]
        let emojis = ["😀", "👍🏽", "❤️", "🎉", "🇺🇦", "👨‍👩‍👧"]
        var text = ""
        var index = 0
        while (text as NSString).length < length {
            text += words[index % words.count]
            if let emojiEvery, index % emojiEvery == emojiEvery - 1 {
                text += " " + emojis[index % emojis.count]
            }
            if let newlineEvery, index % newlineEvery == newlineEvery - 1 {
                text += "\n"
            } else {
                text += " "
            }
            index += 1
        }
        return text
    }

    private func makeView(_ text: String, incremental: Bool) -> ChatInputTextView {
        let view = ChatInputTextView(disableTiling: false)
        view.measuresIncrementally = incremental
        view.frame = CGRect(x: 0.0, y: 0.0, width: self.width, height: 40.0)
        view.attributedText = NSAttributedString(string: text, attributes: self.attributes)
        _ = view.textHeightForWidth(self.width, rightInset: 0.0)
        return view
    }

    private func referenceSize(_ text: NSAttributedString) -> (height: CGFloat, size: CGSize) {
        let view = ChatInputTextView(disableTiling: false)
        view.measuresIncrementally = false
        view.frame = CGRect(x: 0.0, y: 0.0, width: self.width, height: 40.0)
        view.attributedText = text
        let height = view.textHeightForWidth(self.width, rightInset: 0.0)
        return (height, view.measuredTextSizeForTesting)
    }

    private func edit(_ view: ChatInputTextView, range: NSRange, _ replacement: String) {
        view.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: self.attributes))
    }

    func testIncrementalHeightsEqualFullRelayout() {
        for (text, label) in [(self.makeText(30, emojiEvery: nil), "short"), (self.makeText(1000, emojiEvery: nil), "1k"), (self.makeText(1500, emojiEvery: 6), "1.5k+emoji")] {
            let view = self.makeView(text, incremental: true)
            var generator = SystemRandomNumberGenerator()
            let insertions = ["a", " ", "\n", "😀", "👨‍👩‍👧", "longerwordwithoutspaces", "é", "🇺🇦"]
            for step in 0 ..< 60 {
                let length = view.textStorage.length
                let location: Int
                switch step % 3 {
                case 0:
                    location = length
                case 1:
                    location = length / 2
                default:
                    location = Int.random(in: 0 ... length, using: &generator)
                }
                let safeLocation = location == length ? length : (view.textStorage.string as NSString).rangeOfComposedCharacterSequence(at: location).location
                if step % 4 == 3 && safeLocation > 0 {
                    let deleteRange = (view.textStorage.string as NSString).rangeOfComposedCharacterSequence(at: safeLocation - 1)
                    self.edit(view, range: deleteRange, "")
                } else {
                    self.edit(view, range: NSRange(location: safeLocation, length: 0), insertions[step % insertions.count])
                }
                let height = view.textHeightForWidth(self.width, rightInset: 0.0)
                let size = view.measuredTextSizeForTesting
                let reference = self.referenceSize(NSAttributedString(attributedString: view.textStorage))
                XCTAssertEqual(height, reference.height, "\(label) step \(step)")
                XCTAssertEqual(size, reference.size, "\(label) step \(step)")
            }
        }
    }

    func testWidthChangeStillRelayouts() {
        let text = self.makeText(800, emojiEvery: nil)
        let view = self.makeView(text, incremental: true)
        let wide = view.textHeightForWidth(self.width, rightInset: 0.0)
        let narrow = view.textHeightForWidth(200.0, rightInset: 0.0)
        XCTAssertGreaterThan(narrow, wide)
        for (width, rightInset) in [(CGFloat(200.0), CGFloat(0.0)), (self.width, 40.0), (self.width, 0.0)] {
            let reference = ChatInputTextView(disableTiling: false)
            reference.measuresIncrementally = false
            reference.attributedText = NSAttributedString(string: text, attributes: self.attributes)
            XCTAssertEqual(view.textHeightForWidth(width, rightInset: rightInset), reference.textHeightForWidth(width, rightInset: rightInset))
        }
    }

    // Benchmark: measure cost per keystroke (type a letter at the end, measure) at several lengths.
    func testBenchmarkMeasurePerKeystroke() {
        var results: [String] = []
        var fourKRatio: Double = 0.0
        for (label, length, emojiEvery) in [("short", 30, nil as Int?), ("1k", 1000, nil), ("4k", 4000, nil), ("4k+emoji", 4000, 6)] {
            func perKeystroke(incremental: Bool) -> Double {
                let view = self.makeView(self.makeText(length, emojiEvery: emojiEvery), incremental: incremental)
                var best = Double.infinity
                for _ in 0 ..< 3 {
                    let start = CACurrentMediaTime()
                    for i in 0 ..< 20 {
                        let length = view.textStorage.length
                        if i % 2 == 0 {
                            self.edit(view, range: NSRange(location: length, length: 0), "a")
                        } else {
                            self.edit(view, range: NSRange(location: length - 1, length: 1), "")
                        }
                        _ = view.textHeightForWidth(self.width, rightInset: 0.0)
                    }
                    best = min(best, (CACurrentMediaTime() - start) / 20.0)
                }
                return best * 1_000_000.0
            }
            let before = perKeystroke(incremental: false)
            let after = perKeystroke(incremental: true)
            if label == "4k" {
                fourKRatio = before / after
            }
            results.append("\(label) \(String(format: "%.0f", before)) -> \(String(format: "%.0f", after)) us")
        }
        print("BENCH composer measure per keystroke (edit + display relayout + measure): " + results.joined(separator: ", "))
        XCTAssertGreaterThan(fourKRatio, 3.0)
    }
}
