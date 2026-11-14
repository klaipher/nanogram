import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// WATCH-INT-1: push registration plumbing and background refresh scheduling. Both ship off.
@MainActor
final class CorePushAndRefreshTests: XCTestCase {

    // MARK: push

    func testTokenHexIsLowercaseAndZeroPadded() {
        XCTAssertEqual(PushRegistration.hexString(Data([0x00, 0x0A, 0xFF, 0x10])), "000aff10")
        XCTAssertEqual(PushRegistration.hexString(Data()), "")
    }

    func testRegisterDeviceQueryIsTDLibsJSON() throws {
        let data = try RegisterDeviceQuery(tokenHex: "abcd", isSandbox: true).make(with: "x1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["@type"] as? String, "registerDevice")
        XCTAssertEqual(object["@extra"] as? String, "x1")
        let token = try XCTUnwrap(object["device_token"] as? [String: Any])
        XCTAssertEqual(token["@type"] as? String, "deviceTokenApplePush")
        XCTAssertEqual(token["device_token"] as? String, "abcd")
        XCTAssertEqual(token["is_app_sandbox"] as? Bool, true)
        XCTAssertEqual((object["other_user_ids"] as? [Any])?.count, 0)
    }

    func testRegisterDeviceQueryWithoutExtra() throws {
        let data = try RegisterDeviceQuery(tokenHex: "ab", isSandbox: false).make(with: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["@extra"])
    }

    func testTokenStoreDeliversTheCurrentAndLaterTokens() {
        let store = PushTokenStore()
        var received: [Data] = []
        store.set(Data([1]))
        let observation = store.observe { received.append($0) }
        XCTAssertEqual(received, [Data([1])], "a late observer still gets the token")
        store.set(Data([2]))
        store.set(Data([2]))
        XCTAssertEqual(received, [Data([1]), Data([2])], "an unchanged token is not repeated")
        withExtendedLifetime(observation) {}
    }

    func testDroppedObservationStopsCallbacks() async {
        let store = PushTokenStore()
        var received = 0
        var observation: PushTokenObservation? = store.observe { _ in received += 1 }
        store.set(Data([1]))
        XCTAssertEqual(received, 1)
        observation = nil
        _ = observation
        try? await Task.sleep(nanoseconds: 100_000_000)
        store.set(Data([2]))
        XCTAssertEqual(received, 1)
    }

    func testPushFlagShipsOffAndBackgroundRefreshOn() {
        XCTAssertFalse(WatchFeature.pushRegistration.defaultValue)
        XCTAssertTrue(WatchFeature.backgroundRefresh.defaultValue)
    }

    // MARK: background refresh

    private final class FakeScheduler: BackgroundRefreshScheduling {
        private(set) var dates: [Date] = []
        var succeeds = true
        func schedule(preferredDate: Date, completion: @escaping @Sendable (Bool) -> Void) {
            dates.append(preferredDate)
            completion(succeeds)
        }
    }

    private final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 10_000) }

    private func coordinator(scheduler: FakeScheduler, clock: Clock, enabled: Bool = true) -> BackgroundRefreshCoordinator {
        let c = BackgroundRefreshCoordinator(scheduler: scheduler, now: { clock.date })
        c.isEnabled = { enabled }
        return c
    }

    func testNextRefreshIsHalfAnHourAhead() {
        XCTAssertEqual(BackgroundRefreshPlan.nextDate(after: Date(timeIntervalSince1970: 0)), Date(timeIntervalSince1970: 1_800))
    }

    func testDisabledSchedulesNothing() {
        let scheduler = FakeScheduler()
        let c = coordinator(scheduler: scheduler, clock: Clock(), enabled: false)
        XCTAssertFalse(c.scheduleNext())
        XCTAssertTrue(scheduler.dates.isEmpty)
    }

    func testAPendingRefreshIsNotScheduledTwice() {
        let scheduler = FakeScheduler(), clock = Clock()
        let c = coordinator(scheduler: scheduler, clock: clock)
        XCTAssertTrue(c.scheduleNext())
        clock.date.addTimeInterval(60)
        XCTAssertFalse(c.scheduleNext(), "the app goes inactive often; one request is enough")
        XCTAssertEqual(scheduler.dates.count, 1)
        clock.date.addTimeInterval(2_000)
        XCTAssertTrue(c.scheduleNext(), "the pending date has passed")
        XCTAssertEqual(scheduler.dates.count, 2)
    }

    func testAFailedRequestCanBeRetried() async {
        let scheduler = FakeScheduler(), clock = Clock()
        scheduler.succeeds = false
        let c = coordinator(scheduler: scheduler, clock: clock)
        XCTAssertTrue(c.scheduleNext())
        try? await Task.sleep(nanoseconds: 50_000_000)
        scheduler.succeeds = true
        XCTAssertTrue(c.scheduleNext())
    }

    func testRunRefreshSyncsThenSchedulesTheNext() async {
        let scheduler = FakeScheduler(), clock = Clock()
        let c = coordinator(scheduler: scheduler, clock: clock)
        var window: Duration?
        c.syncAction = { window = $0 }
        await c.runRefresh()
        XCTAssertEqual(window, BackgroundRefreshPlan.syncWindow)
        XCTAssertEqual(scheduler.dates, [BackgroundRefreshPlan.nextDate(after: clock.date)])
    }

    func testRunRefreshWhenDisabledDoesNothing() async {
        let scheduler = FakeScheduler()
        let c = coordinator(scheduler: scheduler, clock: Clock(), enabled: false)
        var ran = false
        c.syncAction = { _ in ran = true }
        await c.runRefresh()
        XCTAssertFalse(ran)
        XCTAssertTrue(scheduler.dates.isEmpty)
    }
}
