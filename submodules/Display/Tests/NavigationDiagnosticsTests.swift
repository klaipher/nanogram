import XCTest
@testable import Display

final class NavigationDiagnosticsTests: XCTestCase {
    func testReportListsInputsInOrderAndMarksMissingOnesNever() {
        let report = NavigationDiagnostics.readinessReport(order: ["contentData", "wallpaper", "presentation"], values: ["wallpaper": true, "contentData": false])
        XCTAssertEqual(report, "contentData=false wallpaper=true presentation=never")
    }

    func testRecorderKeepsTheLastValueAndResets() {
        let recorder = NavigationReadinessRecorder(order: ["history", "cachedData"])
        XCTAssertEqual(recorder.report, "history=never cachedData=never")
        recorder.record("history", false)
        recorder.record("history", true)
        XCTAssertEqual(recorder.report, "history=true cachedData=never")
        recorder.reset()
        XCTAssertEqual(recorder.report, "history=never cachedData=never")
    }

    func testEmitIsSilentWithoutALogAndForwardsWithOne() {
        let previous = NavigationDiagnostics.log
        defer {
            NavigationDiagnostics.log = previous
        }
        NavigationDiagnostics.log = nil
        var evaluated = false
        NavigationDiagnostics.emit({ () -> String in
            evaluated = true
            return "x"
        }())
        XCTAssertFalse(evaluated)

        var lines: [String] = []
        NavigationDiagnostics.log = { lines.append($0) }
        NavigationDiagnostics.emit("stack [] -> []")
        XCTAssertEqual(lines, ["stack [] -> []"])
    }

    func testStackDescriptionNamesEachScreenByType() {
        let a = NSObject()
        let b = NSString(string: "s")
        let text = NavigationDiagnostics.describeStack([a, b])
        XCTAssertTrue(text.hasPrefix("[NSObject@"), text)
        XCTAssertTrue(text.hasSuffix("]"), text)
        XCTAssertEqual(NavigationDiagnostics.describe(nil), "nil")
    }
}
