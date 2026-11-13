import XCTest
@testable import TelegramCallsUI

// iOS 13+ stops delivering VoIP pushes to an app that finishes handling one without reporting a
// call to CallKit. Every way out of the app's VoIP push handler must report one.
final class VoIPPushCallReportTests: XCTestCase {
    private var events: [String] = []

    private func makeReport() -> VoIPPushCallReport {
        return VoIPPushCallReport(reportFailedCall: { [unowned self] in
            self.events.append("failed call")
        }, completion: { [unowned self] in
            self.events.append("completion")
        })
    }

    override func setUp() {
        super.setUp()
        self.events = []
    }

    func testAnEarlyExitReportsAFailedCallBeforeCompleting() {
        let report = self.makeReport()
        report.complete()
        XCTAssertEqual(self.events, ["failed call", "completion"])
    }

    func testAReportedCallCompletesWithoutAFailedCall() {
        let report = self.makeReport()
        report.callReported()
        report.complete()
        XCTAssertEqual(self.events, ["completion"])
    }

    func testCompletingTwiceDoesNothingMore() {
        let report = self.makeReport()
        report.complete()
        report.complete()
        XCTAssertEqual(self.events, ["failed call", "completion"])
    }

    // A push the handler is dropping is reported once, however it gets there.
    func testAFailedCallIsReportedOnlyOnce() {
        let report = self.makeReport()
        report.reportFailedCallIfNeeded()
        report.complete()
        XCTAssertEqual(self.events, ["failed call", "completion"])
    }

    func testAPushThatNeedsNoReportCompletesWithoutAPlaceholderCall() {
        var events: [String] = []
        let report = VoIPPushCallReport(mustReport: false, reportFailedCall: {
            events.append("failed call")
        }, completion: {
            events.append("completion")
        })
        report.complete()
        XCTAssertEqual(events, ["completion"])
    }

    func testAPushThatNeedsNoReportStillReportsARealCall() {
        let report = self.makeReport()
        report.callReported()
        report.complete()
        XCTAssertEqual(self.events, ["completion"])
    }
}
