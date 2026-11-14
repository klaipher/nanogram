import Foundation
import XCTest
import SwiftSignalKit
@testable import AnimatedStickerNode

final class AnimatedStickerStatusPublisherTests: XCTestCase {
    func testPublishingWithoutSubscribersDoesNotTouchThePromise() {
        let publisher = AnimatedStickerStatusPublisher()
        for index in 0 ..< 100 {
            publisher.publish(AnimatedStickerStatus(playing: true, duration: 1.0, timestamp: Double(index)))
        }
        XCTAssertEqual(publisher.promiseSetCount, 0)
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
        let seen = Atomic<[Double]>(value: [])
        let disposable = publisher.signal.start(next: { status in
            let all = seen.modify { $0 + [status.timestamp] }
            if all.contains(2.0) {
                received.fulfill()
            }
        })
        publisher.publish(AnimatedStickerStatus(playing: true, duration: 3.0, timestamp: 2.0))
        wait(for: [received], timeout: 5.0)
        disposable.dispose()
    }

    func testDisposedSubscriberStopsTheSets() {
        let publisher = AnimatedStickerStatusPublisher()
        let disposable = publisher.signal.start(next: { _ in })
        publisher.publish(AnimatedStickerStatus(playing: true, duration: 1.0, timestamp: 0.0))
        let afterOne = publisher.promiseSetCount
        XCTAssertEqual(afterOne, 1)
        disposable.dispose()
        publisher.publish(AnimatedStickerStatus(playing: true, duration: 1.0, timestamp: 0.1))
        XCTAssertEqual(publisher.promiseSetCount, afterOne)
    }
}
