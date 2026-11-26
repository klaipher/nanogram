import XCTest
@testable import UniversalMediaPlayer

/// A playing gallery video used to store its resume position every 0.5 s, each store a whole-message rewrite (tester
/// critlogs: one Postbox transaction every 0.50 s while a video played). The throttle keeps steady playback to one
/// store per `periodicInterval` and still stores at once what the user would miss: a pause, a seek, a rate change and
/// the final position when the item closes.
final class MediaPlaybackPositionStoreThrottleTests: XCTestCase {
    private typealias Entry = MediaPlaybackPositionStoreThrottle.Entry

    func testFirstStatusIsStored() {
        var throttle = MediaPlaybackPositionStoreThrottle()
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 30.0, rate: 1.0), seekId: 0, isPlaying: true, now: 100.0))
        XCTAssertEqual(throttle.lastStored, Entry(timestamp: 30.0, rate: 1.0))
    }

    func testSteadyPlaybackStoresOncePerInterval() {
        var throttle = MediaPlaybackPositionStoreThrottle()
        var stores = 0
        // 20 s of playback reported every 0.5 s, as the gallery's status signal does.
        for step in 0 ..< 40 {
            let t = Double(step) * 0.5
            if throttle.shouldStore(Entry(timestamp: 10.0 + t, rate: 1.0), seekId: 0, isPlaying: true, now: 100.0 + t) {
                stores += 1
            }
        }
        // At 0, 5, 10 and 15 s.
        XCTAssertEqual(stores, 4)
    }

    func testInsideTheIntervalIsSkippedAndAfterItIsStored() {
        var throttle = MediaPlaybackPositionStoreThrottle()
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 10.0, rate: 1.0), seekId: 0, isPlaying: true, now: 100.0))
        XCTAssertFalse(throttle.shouldStore(Entry(timestamp: 14.9, rate: 1.0), seekId: 0, isPlaying: true, now: 104.9))
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 15.0, rate: 1.0), seekId: 0, isPlaying: true, now: 105.0))
        XCTAssertEqual(throttle.lastStored, Entry(timestamp: 15.0, rate: 1.0))
    }

    func testUnchangedValueIsNeverStoredAgain() {
        var throttle = MediaPlaybackPositionStoreThrottle()
        // The first and last 5 s of a long video store 0.0; a short video stores nothing.
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 0.0, rate: 1.0), seekId: 0, isPlaying: true, now: 100.0))
        XCTAssertFalse(throttle.shouldStore(Entry(timestamp: 0.0, rate: 1.0), seekId: 0, isPlaying: true, now: 110.0))
        XCTAssertFalse(throttle.shouldStore(Entry(timestamp: 0.0, rate: 1.0), seekId: 0, isPlaying: false, now: 120.0))

        var short = MediaPlaybackPositionStoreThrottle()
        XCTAssertTrue(short.shouldStore(Entry(timestamp: nil, rate: 1.0), seekId: 0, isPlaying: true, now: 100.0))
        XCTAssertFalse(short.shouldStore(Entry(timestamp: nil, rate: 1.0), seekId: 0, isPlaying: true, now: 130.0))
    }

    func testPauseIsStoredAtOnce() {
        var throttle = MediaPlaybackPositionStoreThrottle()
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 10.0, rate: 1.0), seekId: 0, isPlaying: true, now: 100.0))
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 11.0, rate: 1.0), seekId: 0, isPlaying: false, now: 101.0))
        // Still paused at the same place: nothing new to store.
        XCTAssertFalse(throttle.shouldStore(Entry(timestamp: 11.0, rate: 1.0), seekId: 0, isPlaying: false, now: 101.5))
    }

    func testSeekWhilePlayingIsStoredAtOnce() {
        var throttle = MediaPlaybackPositionStoreThrottle()
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 10.0, rate: 1.0), seekId: 0, isPlaying: true, now: 100.0))
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 60.0, rate: 1.0), seekId: 1, isPlaying: true, now: 101.0))
        // The next tick after the seek is ordinary playback again.
        XCTAssertFalse(throttle.shouldStore(Entry(timestamp: 60.5, rate: 1.0), seekId: 1, isPlaying: true, now: 101.5))
    }

    func testSeekToTheSameValueIsStoredAnyway() {
        var throttle = MediaPlaybackPositionStoreThrottle()
        // Another writer may have changed the stored position since; the in-memory duplicate check cannot see that, so
        // a seek always stores (TelegramCore skips the write if the database already holds the value).
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 0.0, rate: 1.0), seekId: 0, isPlaying: true, now: 100.0))
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 0.0, rate: 1.0), seekId: 1, isPlaying: true, now: 101.0))
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 0.0, rate: 1.0), seekId: 2, isPlaying: false, now: 102.0))
        XCTAssertFalse(throttle.shouldStore(Entry(timestamp: 0.0, rate: 1.0), seekId: 2, isPlaying: false, now: 103.0))
    }

    func testRateChangeIsStoredAtOnce() {
        var throttle = MediaPlaybackPositionStoreThrottle()
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 10.0, rate: 1.0), seekId: 0, isPlaying: true, now: 100.0))
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 10.5, rate: 2.0), seekId: 0, isPlaying: true, now: 100.5))
    }

    func testForcedStoreAlwaysGoesThrough() {
        var throttle = MediaPlaybackPositionStoreThrottle()
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 10.0, rate: 1.0), seekId: 0, isPlaying: true, now: 100.0))
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 11.0, rate: 1.0), seekId: 0, isPlaying: true, now: 101.0, force: true))
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 11.0, rate: 1.0), seekId: 0, isPlaying: true, now: 101.1, force: true))
        XCTAssertEqual(throttle.lastStored, Entry(timestamp: 11.0, rate: 1.0))
    }

    func testClockGoingBackwardsDoesNotStopStores() {
        var throttle = MediaPlaybackPositionStoreThrottle()
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 10.0, rate: 1.0), seekId: 0, isPlaying: true, now: 100.0))
        XCTAssertTrue(throttle.shouldStore(Entry(timestamp: 11.0, rate: 1.0), seekId: 0, isPlaying: true, now: 50.0))
    }
}
