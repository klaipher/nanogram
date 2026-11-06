import XCTest
import SwiftSignalKit

final class NanogramSignpostsTests: XCTestCase {
    func testUserLevelNamesAreFewAndUnique() {
        let names = UserSignpost.all.map { "\($0.name)" }
        XCTAssertLessThanOrEqual(names.count, 6)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names, [
            "launchToChatListReady",
            "chatOpenToReady",
            "navigationPushToReady",
            "chatListFirstFrame",
            "chatListFolderSwitch",
            "callConnect"
        ])
    }

    func testHotPathNamesDoNotRepeatUserLevelNames() {
        let hotPath = [
            PerformanceSignpostName.chatHistoryEntriesForView,
            PerformanceSignpostName.chatListPrepareEntries,
            PerformanceSignpostName.composerKeystroke,
            PerformanceSignpostName.composerTextDidChange,
            PerformanceSignpostName.tableMerge,
            PerformanceSignpostName.lottieRenderFrame,
            PerformanceSignpostName.cacheCleanupScan,
            PerformanceSignpostName.automaticCacheEviction,
            PerformanceSignpostName.cacheTouchBatch,
            PerformanceSignpostName.chatControllerCreated,
            PerformanceSignpostName.chatControllerDeinit,
            PerformanceSignpostName.panelScrollTick,
            PerformanceSignpostName.mouseMovedDispatch,
            PerformanceSignpostName.modalOpenToVisible,
            PerformanceSignpostName.launchToChatListUsable,
            PerformanceSignpostName.resumeToFirstFrame,
            PerformanceSignpostName.vp9ResumeCatchUp,
            PerformanceSignpostName.mediaBoxReopen,
            PerformanceSignpostName.chatListRowTap,
            PerformanceSignpostName.navigationPush,
            PerformanceSignpostName.historyFirstContent
        ].map { "\($0)" }
        let user = Set(UserSignpost.all.map { "\($0.name)" })
        XCTAssertTrue(user.isDisjoint(with: hotPath))
    }

    func testIntervalReturnsAndRethrows() {
        XCTAssertEqual(NanogramSignposts.interval(PerformanceSignpostName.tableMerge) { 7 }, 7)
        XCTAssertEqual(NanogramSignposts.interval(.chatOpenToReady) { "x" }, "x")
        struct Failure: Error {}
        XCTAssertThrowsError(try NanogramSignposts.interval(PerformanceSignpostName.tableMerge) { throw Failure() })
    }

    func testOneShotEndsOnce() {
        let shot = NanogramSignposts.OneShot(.callConnect)
        shot.end()
        shot.end()
    }

    func testPendingIntervalOpensAndCloses() {
        XCTAssertFalse(NanogramSignposts.hasPending(.chatListFolderSwitch))
        NanogramSignposts.endPending(.chatListFolderSwitch)
        NanogramSignposts.beginPending(.chatListFolderSwitch)
        XCTAssertTrue(NanogramSignposts.hasPending(.chatListFolderSwitch))
        NanogramSignposts.beginPending(.chatListFolderSwitch)
        XCTAssertTrue(NanogramSignposts.hasPending(.chatListFolderSwitch))
        NanogramSignposts.endPending(.chatListFolderSwitch)
        XCTAssertFalse(NanogramSignposts.hasPending(.chatListFolderSwitch))
    }
}

final class LaunchTaskTrackerTests: XCTestCase {
    private final class Recorder {
        var started: [String] = []
        var finished: [String] = []
    }

    private func makeTracker(_ recorder: Recorder, supported: Bool = true) -> LaunchTaskTracker {
        return LaunchTaskTracker(start: { id in
            recorder.started.append(id)
            guard supported else {
                return nil
            }
            return {
                recorder.finished.append(id)
            }
        })
    }

    func testPhaseIdsAreStable() {
        XCTAssertEqual(LaunchPhase.allCases.map { $0.rawValue }, ["account-load", "chat-list-first-data", "first-frame"])
    }

    func testBeginAndEndEachOnce() {
        let recorder = Recorder()
        let tracker = self.makeTracker(recorder)
        tracker.begin(.accountLoad)
        tracker.begin(.accountLoad)
        XCTAssertEqual(recorder.started, ["account-load"])
        XCTAssertTrue(tracker.isOpen(.accountLoad))
        tracker.end(.accountLoad)
        tracker.end(.accountLoad)
        XCTAssertEqual(recorder.finished, ["account-load"])
        XCTAssertFalse(tracker.isOpen(.accountLoad))
    }

    func testEndWithoutBeginDoesNothing() {
        let recorder = Recorder()
        let tracker = self.makeTracker(recorder)
        tracker.end(.firstFrame)
        tracker.begin(.firstFrame)
        tracker.end(.firstFrame)
        XCTAssertEqual(recorder.finished, ["first-frame"])
    }

    func testPhaseEndedBeforeLateBeginIsNotReopened() {
        let recorder = Recorder()
        let tracker = self.makeTracker(recorder)
        tracker.begin(.chatListFirstData)
        tracker.end(.chatListFirstData)
        tracker.begin(.chatListFirstData)
        XCTAssertEqual(recorder.started, ["chat-list-first-data"])
        XCTAssertFalse(tracker.isOpen(.chatListFirstData))
    }

    func testUnsupportedOSOpensNothingToFinish() {
        let recorder = Recorder()
        let tracker = self.makeTracker(recorder, supported: false)
        tracker.begin(.accountLoad)
        tracker.end(.accountLoad)
        XCTAssertEqual(recorder.finished, [])
    }

    func testLaunchTraceIsSafeOnAnyOS() {
        LaunchTrace.end(.accountLoad)
        LaunchTrace.begin()
        LaunchTrace.begin()
        for phase in LaunchPhase.allCases {
            LaunchTrace.end(phase)
        }
        XCTAssertFalse(NanogramSignposts.hasPending(.launchToChatListReady))
    }

    func testPerformanceNamesAreUnique() {
        let names = [
            PerformanceSignpostName.chatHistoryEntriesForView,
            PerformanceSignpostName.chatListPrepareEntries,
            PerformanceSignpostName.composerKeystroke,
            PerformanceSignpostName.composerTextDidChange,
            PerformanceSignpostName.tableMerge,
            PerformanceSignpostName.lottieRenderFrame,
            PerformanceSignpostName.cacheCleanupScan,
            PerformanceSignpostName.automaticCacheEviction,
            PerformanceSignpostName.cacheTouchBatch,
            PerformanceSignpostName.chatControllerCreated,
            PerformanceSignpostName.chatControllerDeinit,
            PerformanceSignpostName.panelScrollTick,
            PerformanceSignpostName.mouseMovedDispatch,
            PerformanceSignpostName.modalOpenToVisible,
            PerformanceSignpostName.launchToChatListUsable,
            PerformanceSignpostName.resumeToFirstFrame,
            PerformanceSignpostName.vp9ResumeCatchUp,
            PerformanceSignpostName.mediaBoxReopen,
            PerformanceSignpostName.chatListRowTap,
            PerformanceSignpostName.navigationPush,
            PerformanceSignpostName.historyFirstContent
        ].map { "\($0)" }
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testEventDoesNotCrashWhenNothingRecords() {
        NanogramSignposts.event(PerformanceSignpostName.mediaBoxReopen)
    }
}
