import Foundation
import XCTest
import SwiftSignalKit
@testable import LaunchSignpostSupport

final class LaunchSignpostSupportTests: XCTestCase {
    func testBackgroundLaunchEndsEveryPhase() {
        XCTAssertEqual(Set(LaunchSignpostPolicy.phasesToEnd(atLaunchInBackground: true)), Set(LaunchPhase.allCases))
    }

    func testForegroundLaunchEndsNoPhaseEarly() {
        XCTAssertTrue(LaunchSignpostPolicy.phasesToEnd(atLaunchInBackground: false).isEmpty)
    }

    func testBackgroundLaunchClosesTheTracker() {
        var open: Set<String> = []
        let tracker = LaunchTaskTracker(start: { id in
            open.insert(id)
            return { open.remove(id) }
        })
        for phase in LaunchPhase.allCases {
            tracker.begin(phase)
        }
        XCTAssertEqual(open.count, LaunchPhase.allCases.count)
        for phase in LaunchSignpostPolicy.phasesToEnd(atLaunchInBackground: true) {
            tracker.end(phase)
        }
        XCTAssertTrue(open.isEmpty)
    }

    func testCommitCompletionRunsAfterTheCurrentTurn() {
        var didRun = false
        let expectation = self.expectation(description: "commit")
        SignpostCommit.afterNextCommit {
            didRun = true
            XCTAssertTrue(Thread.isMainThread)
            expectation.fulfill()
        }
        XCTAssertFalse(didRun)
        self.wait(for: [expectation], timeout: 5.0)
        XCTAssertTrue(didRun)
    }
}
