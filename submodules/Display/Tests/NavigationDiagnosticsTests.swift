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

    func testDifferingFieldsListsOnlyChangedProperties() {
        struct Settings {
            var keepStack: Bool
            var mode: Int32
            var name: String?
        }
        let defaults = Settings(keepStack: false, mode: 0, name: nil)
        XCTAssertEqual(NavigationDiagnostics.differingFields(defaults, from: defaults), [])
        let changed = Settings(keepStack: true, mode: 0, name: "x")
        XCTAssertEqual(NavigationDiagnostics.differingFields(changed, from: defaults), ["keepStack=true", "name=Optional(\"x\")"])
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
