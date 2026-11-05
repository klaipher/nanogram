import XCTest
import UIKit
@testable import Display

/// Laying out a long message (about 48,000 characters, mixed fonts and a link) with `TextNode`, the text-heavy part
/// of building a chat row. Measures wall clock, CPU and peak memory.
///
/// Skipped unless TG_PERF=1 (see Postbox/Tests/PostboxReadPerformanceTests.swift for how to run and compare).
final class TextLayoutPerformanceTests: XCTestCase {
    private var text = NSAttributedString()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TG_PERF"] == "1", "performance tests run with TG_PERF=1 (tg perf run)")
        let paragraph = "Some words that fill a line of an ordinary message, with emoji \u{1F600} and a link https://example.org/path in it. "
        let result = NSMutableAttributedString(string: String(repeating: paragraph, count: 400), attributes: [
            .font: UIFont.systemFont(ofSize: 16.0),
            .foregroundColor: UIColor.black
        ])
        var location = 0
        while location + 40 < result.length {
            result.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 16.0), range: NSRange(location: location, length: 12))
            location += 300
        }
        self.text = result
    }

    func testLayoutLongMessage() {
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        var lineCount = 0
        self.measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()], options: options) {
            let (layout, _) = TextNode.asyncLayout(nil)(TextNodeLayoutArguments(
                attributedString: self.text,
                maximumNumberOfLines: 0,
                truncationType: .end,
                constrainedSize: CGSize(width: 320.0, height: CGFloat.greatestFiniteMagnitude)
            ))
            lineCount = layout.linesRects().count
        }
        XCTAssertGreaterThan(lineCount, 400)
    }
}
