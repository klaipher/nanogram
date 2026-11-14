import XCTest
@testable import NanogramGlance

/// Widgets, Live Activities and Controls are readable without unlocking the phone: counts are always shown, names
/// only while the app is unlocked and, on lock-screen surfaces, only when the notification setting allows names.
final class GlanceVisibilityTests: XCTestCase {
    func testLockedAppNeverShowsNames() {
        for surface in [GlanceSurface.homeScreen, .lockScreen] {
            for allowed in [true, false] {
                XCTAssertFalse(GlanceVisibility.showsNames(surface: surface, lock: .locked, displayNameOnLockscreen: allowed))
            }
        }
    }

    func testLockScreenFollowsTheNotificationSetting() {
        XCTAssertTrue(GlanceVisibility.showsNames(surface: .lockScreen, lock: .unlocked, displayNameOnLockscreen: true))
        XCTAssertFalse(GlanceVisibility.showsNames(surface: .lockScreen, lock: .unlocked, displayNameOnLockscreen: false))
        XCTAssertTrue(GlanceVisibility.showsNames(surface: .lockScreen, lock: .locksIn(30), displayNameOnLockscreen: true))
    }

    func testHomeScreenShowsNamesWhenUnlocked() {
        XCTAssertTrue(GlanceVisibility.showsNames(surface: .homeScreen, lock: .unlocked, displayNameOnLockscreen: false))
    }

    func testTitleFallsBackToTheGenericOne() {
        XCTAssertEqual(GlanceVisibility.title(name: "Anna", genericTitle: "Nanogram", showsNames: true), "Anna")
        XCTAssertEqual(GlanceVisibility.title(name: "Anna", genericTitle: "Nanogram", showsNames: false), "Nanogram")
        XCTAssertEqual(GlanceVisibility.title(name: "", genericTitle: "Nanogram", showsNames: true), "Nanogram")
    }
}

final class GlanceTimelineTests: XCTestCase {
    func testStepsFollowTheLockPhase() {
        XCTAssertEqual(GlanceTimeline.steps(lock: .unlocked), [GlanceTimelineStep(offsetSeconds: 0, isLocked: false)])
        XCTAssertEqual(GlanceTimeline.steps(lock: .locked), [GlanceTimelineStep(offsetSeconds: 0, isLocked: true)])
        XCTAssertEqual(GlanceTimeline.steps(lock: .locksIn(90)), [GlanceTimelineStep(offsetSeconds: 0, isLocked: false), GlanceTimelineStep(offsetSeconds: 90, isLocked: true)])
        XCTAssertEqual(GlanceTimeline.steps(lock: .locksIn(0)).last, GlanceTimelineStep(offsetSeconds: 1, isLocked: true))
    }

    func testUnreadTotalSkipsMutedChats() {
        XCTAssertEqual(GlanceCount.total([(3, false), (10, true), (0, false), (2, false)]), 5)
        XCTAssertEqual(GlanceCount.text(1500), "999+")
        XCTAssertEqual(GlanceCount.text(7), "7")
    }
}

final class GlanceStoreTests: XCTestCase {
    private var directory: String = ""

    override func setUp() {
        super.setUp()
        self.directory = NSTemporaryDirectory() + "glance-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    func testRoundTrip() {
        let saved = GlancePeerRef(accountId: 5, peerId: 77, title: "Saved Messages", isSavedMessages: true)
        let snapshot = GlanceSnapshot(enabled: true, displayNameOnLockscreen: false, peers: [saved, GlancePeerRef(accountId: 5, peerId: 9, title: "Anna")], savedMessages: saved)
        XCTAssertTrue(GlanceStore.write(snapshot, rootPath: self.directory))
        XCTAssertEqual(GlanceStore.read(rootPath: self.directory), snapshot)
        GlanceStore.remove(rootPath: self.directory)
        XCTAssertNil(GlanceStore.read(rootPath: self.directory))
    }

    func testUnknownVersionIsIgnored() throws {
        let json = "{\"version\":99,\"enabled\":true,\"displayNameOnLockscreen\":true,\"peers\":[]}"
        try json.write(toFile: GlanceStore.path(rootPath: self.directory), atomically: true, encoding: .utf8)
        XCTAssertNil(GlanceStore.read(rootPath: self.directory))
    }

    func testIdentifierMatchesTheSiriKitFormat() {
        let ref = GlancePeerRef(accountId: -3, peerId: 12, title: "x")
        XCTAssertEqual(ref.identifier, "-3:12")
        let parsed = GlanceIdentifier.parse("-3:12")
        XCTAssertEqual(parsed?.accountId, -3)
        XCTAssertEqual(parsed?.peerId, 12)
        XCTAssertNil(GlanceIdentifier.parse("12"))
        XCTAssertNil(GlanceIdentifier.parse("a:b"))
    }

    func testGroupCandidatesCoverExtensions() {
        XCTAssertEqual(GlanceLocation.groupIdentifierCandidates(bundleIdentifier: "org.x.Nanogram.Widget"), ["group.org.x.Nanogram.Widget", "group.org.x.Nanogram"])
    }
}
