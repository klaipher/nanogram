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

    func testOnlyStallAndRecoveryLinesGoToTheShortLog() {
        XCTAssertTrue(NavigationDiagnostics.belongsInShortLog("stall: ChatControllerImpl@1234 not ready after 3.0 s; waits for history=never"))
        XCTAssertTrue(NavigationDiagnostics.belongsInShortLog("stall: transition push to ChatControllerImpl@1234 still running after 3.0 s"))
        XCTAssertTrue(NavigationDiagnostics.belongsInShortLog("recovery: showing ChatControllerImpl@1234 not ready after 5.0 s"))
        XCTAssertTrue(NavigationDiagnostics.belongsInShortLog("recovery: landing transition push to ChatControllerImpl@1234 still running after 3.0 s"))
        XCTAssertFalse(NavigationDiagnostics.belongsInShortLog("stack [] -> [ChatListControllerImpl@1] top=ChatListControllerImpl@1"))
        XCTAssertFalse(NavigationDiagnostics.belongsInShortLog("pending push ChatControllerImpl@1234 ready=false"))
        XCTAssertFalse(NavigationDiagnostics.belongsInShortLog("transition start push ChatListControllerImpl@1 -> ChatControllerImpl@1234"))
        XCTAssertFalse(NavigationDiagnostics.belongsInShortLog("transition end push -> ChatControllerImpl@1234"))
        XCTAssertFalse(NavigationDiagnostics.belongsInShortLog("ready ChatControllerImpl@1234 current=true"))
        XCTAssertFalse(NavigationDiagnostics.belongsInShortLog("root container -> flat width=compact size=402.0x874.0 controllers=[]"))
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

    func testAStalledScreenIsShownOnlyWhenStillPendingNotReadyAndOptedIn() {
        XCTAssertTrue(NavigationRecovery.showsPendingScreen(isStillPending: true, isReady: false, optedIn: true))
        XCTAssertFalse(NavigationRecovery.showsPendingScreen(isStillPending: false, isReady: false, optedIn: true))
        XCTAssertFalse(NavigationRecovery.showsPendingScreen(isStillPending: true, isReady: true, optedIn: true))
        XCTAssertFalse(NavigationRecovery.showsPendingScreen(isStillPending: true, isReady: false, optedIn: false))
    }

    func testAStuckTransitionIsLandedOnlyWhenNothingSteersIt() {
        XCTAssertTrue(NavigationRecovery.landsTransition(isStillRunning: true, isInteractive: false, hasInteractivePop: false))
        XCTAssertFalse(NavigationRecovery.landsTransition(isStillRunning: false, isInteractive: false, hasInteractivePop: false))
        XCTAssertFalse(NavigationRecovery.landsTransition(isStillRunning: true, isInteractive: true, hasInteractivePop: false))
        XCTAssertFalse(NavigationRecovery.landsTransition(isStillRunning: true, isInteractive: false, hasInteractivePop: true))
    }

    func testRecoveryWaitsLongerThanANormalOpenAndAnimation() {
        XCTAssertGreaterThanOrEqual(NavigationRecovery.pendingReadyTimeout, 3.0)
        XCTAssertGreaterThanOrEqual(NavigationRecovery.transitionTimeout, 2.0)
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
