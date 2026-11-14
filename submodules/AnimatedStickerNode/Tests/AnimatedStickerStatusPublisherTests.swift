import Foundation
import XCTest
import SwiftSignalKit
@testable import AnimatedStickerNode

final class AnimatedStickerStatusPublisherTests: XCTestCase {
    func testPublishingWithoutSubscribersDeliversNothing() {
        let publisher = AnimatedStickerStatusPublisher()
        for index in 0 ..< 100 {
            publisher.publish(AnimatedStickerStatus(playing: true, duration: 1.0, timestamp: Double(index)))
        }
        XCTAssertEqual(publisher.deliveryCount, 0)
        XCTAssertFalse(publisher.hasSubscribers)
    }

    func testFirstSubscriberReceivesTheLatestStatus() {
        let publisher = AnimatedStickerStatusPublisher()
        publisher.publish(AnimatedStickerStatus(playing: true, duration: 1.0, timestamp: 0.1))
        publisher.publish(AnimatedStickerStatus(playing: false, duration: 1.0, timestamp: 0.5))
        let received = expectation(description: "status")
        let disposable = publisher.signal.start(next: { status in
            XCTAssertEqual(status, AnimatedStickerStatus(playing: false, duration: 1.0, timestamp: 0.5))
            received.fulfill()
        })
        wait(for: [received], timeout: 5.0)
        XCTAssertTrue(publisher.hasSubscribers)
        disposable.dispose()
        XCTAssertFalse(publisher.hasSubscribers)
    }

    func testSubscriberSeesLaterPublishes() {
        let publisher = AnimatedStickerStatusPublisher()
        let received = expectation(description: "second status")
        let fulfilled = Atomic<Bool>(value: false)
        let disposable = publisher.signal.start(next: { status in
            if status.timestamp == 2.0, !fulfilled.swap(true) {
                received.fulfill()
            }
        })
        let registered = expectation(description: "registered")
        Queue.mainQueue().async {
            registered.fulfill()
        }
        wait(for: [registered], timeout: 5.0)
        publisher.publish(AnimatedStickerStatus(playing: true, duration: 3.0, timestamp: 2.0))
        wait(for: [received], timeout: 5.0)
        disposable.dispose()
    }

    func testSubscriberAfterAnUnobservedStretchOnlySeesTheLatestStatus() {
        let publisher = AnimatedStickerStatusPublisher()
        publisher.publish(AnimatedStickerStatus(playing: true, duration: 1.0, timestamp: 0.1))
        let first = publisher.signal.start(next: { _ in })
        let registered = expectation(description: "registered")
        Queue.mainQueue().async {
            registered.fulfill()
        }
        wait(for: [registered], timeout: 5.0)
        first.dispose()
        publisher.publish(AnimatedStickerStatus(playing: true, duration: 2.0, timestamp: 0.9))
        let seen = Atomic<[Double]>(value: [])
        let done = expectation(description: "latest")
        let second = publisher.signal.start(next: { status in
            let _ = seen.modify { $0 + [status.timestamp] }
            done.fulfill()
        })
        wait(for: [done], timeout: 5.0)
        XCTAssertEqual(seen.with { $0 }, [0.9])
        second.dispose()
    }

    func testDisposedSubscriberStopsTheSets() {
        let publisher = AnimatedStickerStatusPublisher()
        let disposable = publisher.signal.start(next: { _ in })
        let registered = expectation(description: "registered")
        Queue.mainQueue().async {
            registered.fulfill()
        }
        wait(for: [registered], timeout: 5.0)
        publisher.publish(AnimatedStickerStatus(playing: true, duration: 1.0, timestamp: 0.0))
        let afterOne = publisher.deliveryCount
        XCTAssertEqual(afterOne, 1)
        disposable.dispose()
        publisher.publish(AnimatedStickerStatus(playing: true, duration: 1.0, timestamp: 0.1))
        XCTAssertEqual(publisher.deliveryCount, afterOne)
    }
}
