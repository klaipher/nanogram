import XCTest
import TelegramCore
@testable import NotificationServiceExtensionLib

final class IncomingCallRingWatchTests: XCTestCase {
    /// A fake clock and timer: `advance` runs the scheduled actions in time order.
    private final class Harness {
        var time = 0.0
        var scheduled: [(at: Double, action: () -> Void)] = []
        var probes: [Double] = []
        var removals = 0
        var results: [IncomingCallProbeResult] = []
        var logs: [String] = []
        var end: IncomingCallRingWatch.End?
        let key: String

        init(key: String = UUID().uuidString) {
            self.key = key
        }

        @discardableResult
        func begin(window: Double = 30.0) -> IncomingCallRingWatch? {
            return IncomingCallRingWatch.begin(
                key: self.key,
                interval: 2.0,
                window: window,
                probe: { done in
                    self.probes.append(self.time)
                    done(self.results.isEmpty ? .ringing : self.results.removeFirst())
                },
                removeRing: { done in
                    self.removals += 1
                    done(1)
                },
                schedule: { delay, action in
                    self.scheduled.append((self.time + delay, action))
                },
                now: { self.time },
                log: { self.logs.append($0) },
                onFinished: { self.end = $0 }
            )
        }

        func advance(to target: Double) {
            while let index = self.scheduled.indices.min(by: { self.scheduled[$0].at < self.scheduled[$1].at }), self.scheduled[index].at <= target {
                let item = self.scheduled.remove(at: index)
                self.time = item.at
                item.action()
            }
            self.time = target
        }
    }

    func testAsksEveryTwoSecondsUntilTheWindowEnds() {
        let harness = Harness()
        harness.begin()
        harness.advance(to: 40.0)
        XCTAssertEqual(harness.probes.first, 2.0)
        XCTAssertEqual(harness.probes.prefix(3), [2.0, 4.0, 6.0])
        XCTAssertLessThanOrEqual(harness.probes.last ?? 0.0, 30.0)
        XCTAssertEqual(harness.end, .window)
        XCTAssertEqual(harness.removals, 0)
    }

    func testRemovesTheRingOnceWhenTheCallEnded() {
        let harness = Harness()
        harness.results = [.ringing, .unknown, .ended("rpc 400 CALL_ALREADY_DECLINED")]
        harness.begin()
        harness.advance(to: 60.0)
        XCTAssertEqual(harness.probes, [2.0, 4.0, 6.0])
        XCTAssertEqual(harness.removals, 1)
        XCTAssertEqual(harness.end, .ended)
        XCTAssertTrue(harness.logs.contains(where: { $0.contains("ended(rpc 400 CALL_ALREADY_DECLINED)") }))
        XCTAssertTrue(harness.logs.contains(where: { $0.hasPrefix("ring removed by watch") }))
    }

    func testUnknownKeepsTheRing() {
        let harness = Harness()
        harness.results = [.unknown, .unknown, .unknown]
        harness.begin()
        harness.advance(to: 7.0)
        XCTAssertEqual(harness.removals, 0)
        XCTAssertNil(harness.end)
    }

    func testExpiryStopsTheWatchAndLogsIt() {
        let harness = Harness()
        let watch = harness.begin()
        harness.advance(to: 5.0)
        watch?.expire()
        harness.advance(to: 60.0)
        XCTAssertEqual(harness.end, .expired)
        XCTAssertEqual(harness.probes, [2.0, 4.0])
        XCTAssertTrue(harness.logs.contains(where: { $0.hasPrefix("watch end expired") }))
    }

    func testRepeatedPushStartsNoSecondWatch() {
        let harness = Harness()
        XCTAssertNotNil(harness.begin())
        XCTAssertNil(harness.begin())
        XCTAssertTrue(IncomingCallRingWatch.isWatching(key: harness.key))
        harness.advance(to: 40.0)
        XCTAssertFalse(IncomingCallRingWatch.isWatching(key: harness.key))
        XCTAssertNotNil(harness.begin())
    }
}
