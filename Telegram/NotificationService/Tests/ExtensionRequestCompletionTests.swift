import Foundation
import XCTest
@testable import NotificationServiceExtensionLib

/// The extension hands its content back only after its databases stopped taking new transactions
/// (or a timeout passed), and keeps a process activity until they did, so iOS does not suspend it
/// while it holds a SQLite lock in the shared container (0xdead10cc).
final class ExtensionRequestCompletionTests: XCTestCase {
    private final class FakeActivity {
        var begun = 0
        var ended = 0
        var isActive: Bool {
            return self.begun > self.ended
        }

        func begin() -> () -> Void {
            self.begun += 1
            return { [weak self] in
                self?.ended += 1
            }
        }
    }

    private final class FakeScheduler {
        var pending: [(delay: Double, action: () -> Void)] = []

        func schedule(_ delay: Double, _ action: @escaping () -> Void) {
            self.pending.append((delay, action))
        }

        func fire(delay: Double) {
            let matching = self.pending.filter { $0.delay == delay }
            self.pending.removeAll(where: { $0.delay == delay })
            for item in matching {
                item.action()
            }
        }
    }

    private final class FakeDatabases {
        var pauseRequests = 0
        var completions: [() -> Void] = []

        func pause(_ completion: @escaping () -> Void) {
            self.pauseRequests += 1
            self.completions.append(completion)
        }

        func finishPausing() {
            let completions = self.completions
            self.completions = []
            for completion in completions {
                completion()
            }
        }
    }

    private let deliverTimeout = 1.0
    private let activityTimeout = 5.0

    private func finish(_ completion: ExtensionRequestCompletion, databases: FakeDatabases, scheduler: FakeScheduler, deliverTimeout: Double? = nil, deliver: @escaping () -> Void) {
        completion.finish(
            pauseDatabases: { done in
                databases.pause(done)
            },
            deliverTimeout: deliverTimeout ?? self.deliverTimeout,
            activityTimeout: self.activityTimeout,
            schedule: { delay, action in
                scheduler.schedule(delay, action)
            },
            deliver: deliver
        )
    }

    func testActivityBeginsWithTheRequest() {
        let activity = FakeActivity()
        let completion = ExtensionRequestCompletion(beginActivity: activity.begin)
        XCTAssertTrue(activity.isActive)
        withExtendedLifetime(completion, {})
    }

    func testDeliversOnlyAfterDatabasesPaused() {
        let activity = FakeActivity()
        let databases = FakeDatabases()
        let scheduler = FakeScheduler()
        var events: [String] = []
        let completion = ExtensionRequestCompletion(beginActivity: activity.begin)
        self.finish(completion, databases: databases, scheduler: scheduler, deliver: {
            events.append("deliver")
        })
        XCTAssertEqual(databases.pauseRequests, 1)
        XCTAssertEqual(events, [])
        XCTAssertTrue(activity.isActive)

        databases.finishPausing()
        XCTAssertEqual(events, ["deliver"])
        XCTAssertFalse(activity.isActive)
        XCTAssertEqual(activity.ended, 1)

        // Timers firing later change nothing.
        scheduler.fire(delay: self.deliverTimeout)
        scheduler.fire(delay: self.activityTimeout)
        XCTAssertEqual(events, ["deliver"])
        XCTAssertEqual(activity.ended, 1)
    }

    func testDeliversAfterTimeoutWhenPauseHangs() {
        let activity = FakeActivity()
        let databases = FakeDatabases()
        let scheduler = FakeScheduler()
        var delivered = 0
        let completion = ExtensionRequestCompletion(beginActivity: activity.begin)
        self.finish(completion, databases: databases, scheduler: scheduler, deliver: {
            delivered += 1
        })
        scheduler.fire(delay: self.deliverTimeout)
        XCTAssertEqual(delivered, 1)
        // A transaction may still be running: the activity stays.
        XCTAssertTrue(activity.isActive)

        databases.finishPausing()
        XCTAssertEqual(delivered, 1)
        XCTAssertFalse(activity.isActive)
    }

    func testActivityEndsAfterItsTimeoutWhenPauseNeverCompletes() {
        let activity = FakeActivity()
        let databases = FakeDatabases()
        let scheduler = FakeScheduler()
        var delivered = 0
        let completion = ExtensionRequestCompletion(beginActivity: activity.begin)
        self.finish(completion, databases: databases, scheduler: scheduler, deliver: {
            delivered += 1
        })
        scheduler.fire(delay: self.activityTimeout)
        XCTAssertEqual(delivered, 1)
        XCTAssertFalse(activity.isActive)
        scheduler.fire(delay: self.deliverTimeout)
        databases.finishPausing()
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(activity.ended, 1)
    }

    func testExpireDeliversPendingContentAtOnce() {
        let activity = FakeActivity()
        let databases = FakeDatabases()
        let scheduler = FakeScheduler()
        var delivered = 0
        let completion = ExtensionRequestCompletion(beginActivity: activity.begin)
        self.finish(completion, databases: databases, scheduler: scheduler, deliver: {
            delivered += 1
        })
        completion.expire()
        XCTAssertEqual(delivered, 1)
        XCTAssertTrue(activity.isActive)
        databases.finishPausing()
        XCTAssertEqual(delivered, 1)
        XCTAssertFalse(activity.isActive)
    }

    /// The time-will-expire path delivers right away but still stops the databases.
    func testImmediateDeliveryStillPausesDatabases() {
        let activity = FakeActivity()
        let databases = FakeDatabases()
        let scheduler = FakeScheduler()
        var events: [String] = []
        let completion = ExtensionRequestCompletion(beginActivity: activity.begin)
        self.finish(completion, databases: databases, scheduler: scheduler, deliverTimeout: 0.0, deliver: {
            events.append("deliver")
        })
        XCTAssertEqual(events, ["deliver"])
        XCTAssertEqual(databases.pauseRequests, 1)
        XCTAssertTrue(activity.isActive)
        databases.finishPausing()
        XCTAssertFalse(activity.isActive)
    }

    func testSynchronousPauseDeliversImmediately() {
        let activity = FakeActivity()
        let scheduler = FakeScheduler()
        var delivered = 0
        let completion = ExtensionRequestCompletion(beginActivity: activity.begin)
        completion.finish(pauseDatabases: { done in
            done()
        }, deliverTimeout: self.deliverTimeout, activityTimeout: self.activityTimeout, schedule: { delay, action in
            scheduler.schedule(delay, action)
        }, deliver: {
            delivered += 1
        })
        XCTAssertEqual(delivered, 1)
        XCTAssertFalse(activity.isActive)
    }

    func testSecondFinishDoesNotDeliverAgain() {
        let activity = FakeActivity()
        let databases = FakeDatabases()
        let scheduler = FakeScheduler()
        var delivered: [Int] = []
        let completion = ExtensionRequestCompletion(beginActivity: activity.begin)
        self.finish(completion, databases: databases, scheduler: scheduler, deliver: {
            delivered.append(1)
        })
        self.finish(completion, databases: databases, scheduler: scheduler, deliver: {
            delivered.append(2)
        })
        databases.finishPausing()
        XCTAssertEqual(delivered, [1])
        XCTAssertEqual(activity.ended, 1)
    }

    /// A request replaced before it finished (or a handler that failed to start) must not leave
    /// the activity running.
    func testActivityEndsWhenDroppedUnfinished() {
        let activity = FakeActivity()
        var completion: ExtensionRequestCompletion? = ExtensionRequestCompletion(beginActivity: activity.begin)
        XCTAssertTrue(activity.isActive)
        completion = nil
        XCTAssertNil(completion)
        XCTAssertFalse(activity.isActive)
    }

    func testExpiringActivityReleasesItsBlock() {
        let started = self.expectation(description: "started")
        let returned = self.expectation(description: "returned")
        let activity = ExpiringProcessActivity(reason: "test", perform: { block in
            DispatchQueue.global().async {
                started.fulfill()
                block(false)
                returned.fulfill()
            }
        })
        self.wait(for: [started], timeout: 5.0)
        activity.end()
        self.wait(for: [returned], timeout: 5.0)
    }

    func testExpiringActivityStopsWaitingWhenExpired() {
        let returned = self.expectation(description: "returned")
        var expire: (() -> Void)?
        let activity = ExpiringProcessActivity(reason: "test", perform: { block in
            expire = {
                block(true)
            }
            DispatchQueue.global().async {
                block(false)
                returned.fulfill()
            }
        })
        expire?()
        self.wait(for: [returned], timeout: 5.0)
        activity.end()
    }
}
