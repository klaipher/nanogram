import Foundation

private let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType([.link]).rawValue)

/// Links typed in a draft: what NSDataDetector finds in the text, then the text-link (`textUrl`) attributes not
/// already among them, in order.
///
/// Runs on every chat state update while typing, often twice per keystroke. A whole-text scan costs 1.5-3 ms at
/// 4k characters, so results are cached per line (a link never spans a newline) and only edited lines are scanned
/// again. The cache holds the lines of the last text only.
public final class ChatInputUrlDetector {
    public static let shared = ChatInputUrlDetector()

    private let lock = NSLock()
    private var lineCache: [String: [String]] = [:]
    private var lastText: String?
    private var lastLinks: [String] = []
    var scannedLinesForTesting = 0

    public init() {
    }

    public func detectUrls(_ inputText: NSAttributedString?) -> [String] {
        guard let inputText, let linkDetector else {
            return []
        }
        let string = inputText.string
        var detectedUrls = self.links(in: string, detector: linkDetector)

        inputText.enumerateAttribute(ChatTextInputAttributes.textUrl, in: NSRange(location: 0, length: inputText.length), options: [], using: { value, _, _ in
            if let value = value as? ChatTextInputTextUrlAttribute {
                if !detectedUrls.contains(value.url) {
                    detectedUrls.append(value.url)
                }
            }
        })
        return detectedUrls
    }

    private func links(in string: String, detector: NSDataDetector) -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let lastText = self.lastText, lastText == string {
            return self.lastLinks
        }

        let text = string as NSString
        let length = text.length
        var links: [String] = []
        var updatedCache: [String: [String]] = [:]
        var lineStart = 0
        while lineStart <= length {
            let newline = text.range(of: "\n", options: .literal, range: NSRange(location: lineStart, length: length - lineStart))
            let lineEnd = newline.location == NSNotFound ? length : newline.location
            let line = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let lineLinks: [String]
            if let cached = updatedCache[line] ?? self.lineCache[line] {
                lineLinks = cached
            } else {
                self.scannedLinesForTesting += 1
                let lineText = line as NSString
                lineLinks = detector.matches(in: line, options: [], range: NSRange(location: 0, length: lineText.length)).map { lineText.substring(with: $0.range) }
            }
            updatedCache[line] = lineLinks
            links.append(contentsOf: lineLinks)
            lineStart = lineEnd + 1
        }
        self.lineCache = updatedCache
        self.lastText = string
        self.lastLinks = links
        return links
    }
}

/// `string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` without copying the string.
public func stringIsEmptyOrWhitespace(_ string: String) -> Bool {
    return (string as NSString).rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted).location == NSNotFound
}
