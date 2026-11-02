import XCTest
import QuartzCore
@testable import TextFormat

/// Link detection in the draft used to run NSDataDetector over the whole text on every state update (1.5-3 ms at
/// 4k characters, often twice per keystroke). It now caches per line; the links found must be the same.
final class ChatInputUrlDetectionTests: XCTestCase {
    private let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType([.link]).rawValue)

    // The detection as it was: the whole text at once.
    private func reference(_ inputText: NSAttributedString) -> [String] {
        var detectedUrls: [String] = []
        let nsRange = NSRange(location: 0, length: inputText.string.utf16.count)
        for match in self.detector.matches(in: inputText.string, options: [], range: nsRange) {
            detectedUrls.append((inputText.string as NSString).substring(with: match.range))
        }
        inputText.enumerateAttribute(ChatTextInputAttributes.textUrl, in: nsRange, options: [], using: { value, _, _ in
            if let value = value as? ChatTextInputTextUrlAttribute, !detectedUrls.contains(value.url) {
                detectedUrls.append(value.url)
            }
        })
        return detectedUrls
    }

    private var corpus: [String] {
        let pieces = ["hello", "telegram.org", "https://t.me/durov?x=1", "www.apple.com/iphone", "mailto:a@b.com", "user@example.com", "+380 44 123 45 67", "ftp://files.example.org/a.zip", "example.com.", "(https://x.y/z)", "http://localhost:8080/path", "привіт.укр", "t.me/joinchat/ABC", "😀", "word,", "a.b", "1.2.3", "github.com/apple/swift/pull/1", "tg://resolve?domain=x", "\u{2028}", "\r", "\t", "https://example.com/very/long/" + String(repeating: "segment/", count: 30)]
        var generator = SeededGenerator(seed: 42)
        var texts: [String] = ["", "\n", "\n\n", "telegram.org\n", "\ntelegram.org", "telegram.org\ntelegram.org", "https://a.com\nb.com\n\nc.org d.net"]
        for _ in 0 ..< 400 {
            var text = ""
            for _ in 0 ..< Int.random(in: 1 ... 40, using: &generator) {
                text += pieces[Int.random(in: 0 ..< pieces.count, using: &generator)]
                text += [" ", " ", "\n", "", ". ", ", "][Int.random(in: 0 ..< 6, using: &generator)]
            }
            texts.append(text)
        }
        return texts
    }

    func testSameLinksAsWholeTextScan() {
        let detector = ChatInputUrlDetector()
        for text in self.corpus {
            let attributed = NSAttributedString(string: text)
            XCTAssertEqual(detector.detectUrls(attributed), self.reference(attributed), text.debugDescription)
        }
    }

    func testTextLinkAttributesAreAppended() {
        let string = NSMutableAttributedString(string: "see telegram.org and this")
        string.addAttribute(ChatTextInputAttributes.textUrl, value: ChatTextInputTextUrlAttribute(url: "https://core.telegram.org"), range: NSRange(location: 21, length: 4))
        string.addAttribute(ChatTextInputAttributes.textUrl, value: ChatTextInputTextUrlAttribute(url: "telegram.org"), range: NSRange(location: 0, length: 3))
        let detector = ChatInputUrlDetector()
        XCTAssertEqual(detector.detectUrls(string), self.reference(string))
        XCTAssertEqual(detector.detectUrls(string), ["telegram.org", "https://core.telegram.org"])
        // Same text, different attributes: the attributes are read again.
        XCTAssertEqual(detector.detectUrls(NSAttributedString(string: string.string)), ["telegram.org"])
        XCTAssertEqual(detector.detectUrls(nil), [])
    }

    func testTypingScansOnlyTheEditedLine() {
        let detector = ChatInputUrlDetector()
        var text = (0 ..< 50).map { "line \($0) with telegram.org/\($0) in it" }.joined(separator: "\n")
        _ = detector.detectUrls(NSAttributedString(string: text))
        let scanned = detector.scannedLinesForTesting
        text += " x"
        XCTAssertEqual(detector.detectUrls(NSAttributedString(string: text)), self.reference(NSAttributedString(string: text)))
        XCTAssertEqual(detector.scannedLinesForTesting - scanned, 1)
        // The same text again (a second state update for the same keystroke) scans nothing.
        _ = detector.detectUrls(NSAttributedString(string: text))
        XCTAssertEqual(detector.scannedLinesForTesting - scanned, 1)
    }

    // Benchmark: one keystroke at the end of a draft, two state updates per keystroke as today.
    func testBenchmarkDetectionPerKeystroke() {
        var lines: [String] = []
        for (label, length) in [("short", 30), ("1k", 1000), ("4k", 4000)] {
            var base = ""
            var index = 0
            while base.utf16.count < length {
                base += ["hello", "telegram.org/fox", "привіт", "https://t.me/dog?x=1", "quick", "brown 😀"][index % 6]
                base += index % 12 == 11 ? "\n" : " "
                index += 1
            }
            func perKeystroke(_ body: (NSAttributedString) -> [String]) -> Double {
                var text = base
                var best = Double.infinity
                for _ in 0 ..< 3 {
                    let start = CACurrentMediaTime()
                    for _ in 0 ..< 10 {
                        text += "a"
                        let attributed = NSAttributedString(string: text)
                        _ = body(attributed)
                        _ = body(attributed)
                    }
                    best = min(best, (CACurrentMediaTime() - start) / 10.0)
                }
                return best * 1_000_000.0
            }
            let before = perKeystroke { self.reference($0) }
            let detector = ChatInputUrlDetector()
            let after = perKeystroke { detector.detectUrls($0) }
            lines.append("\(label) \(String(format: "%.0f", before)) -> \(String(format: "%.0f", after)) us")
        }
        print("BENCH draft link detection per keystroke (2 state updates): " + lines.joined(separator: ", "))
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        self.state = seed
    }
    mutating func next() -> UInt64 {
        self.state &+= 0x9E3779B97F4A7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class StringIsEmptyOrWhitespaceTests: XCTestCase {
    func testMatchesTrimmingIsEmpty() {
        let samples = ["", " ", "\n", " \n\t\r ", "\u{00A0}", "\u{2028}", "\u{3000}", "\u{200B}", "a", " a ", "\n\n😀", "\u{FEFF}", "\u{0085}", String(repeating: " ", count: 4000), String(repeating: " ", count: 4000) + "x"]
        for sample in samples {
            XCTAssertEqual(stringIsEmptyOrWhitespace(sample), sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sample.debugDescription)
        }
    }
}
