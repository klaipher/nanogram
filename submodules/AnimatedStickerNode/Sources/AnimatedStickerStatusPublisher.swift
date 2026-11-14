import Foundation
import SwiftSignalKit

/// The playback status of one node. A node publishes it on every frame, so while nobody observes `signal`
/// the latest value is only remembered (main queue) and handed to the first subscriber, which is what the
/// Promise it replaces did.
final class AnimatedStickerStatusPublisher {
    private let promise = Promise<AnimatedStickerStatus>()
    private let subscriberCount = Atomic<Int>(value: 0)
    private var latest: AnimatedStickerStatus?
    private(set) var promiseSetCount: Int = 0

    var hasSubscribers: Bool {
        return self.subscriberCount.with { $0 } > 0
    }

    var signal: Signal<AnimatedStickerStatus, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                return EmptyDisposable
            }
            let _ = self.subscriberCount.modify { $0 + 1 }
            let disposable = self.promise.get().start(next: { next in
                subscriber.putNext(next)
            })
            Queue.mainQueue().async { [weak self] in
                self?.flushLatest()
            }
            return ActionDisposable { [weak self] in
                disposable.dispose()
                let _ = self?.subscriberCount.modify { $0 - 1 }
            }
        }
    }

    /// Main queue only.
    func publish(_ status: AnimatedStickerStatus) {
        self.latest = status
        if self.hasSubscribers {
            self.set(status)
        }
    }

    private func flushLatest() {
        if self.hasSubscribers, let latest = self.latest {
            self.set(latest)
        }
    }

    private func set(_ status: AnimatedStickerStatus) {
        self.promiseSetCount += 1
        self.promise.set(.single(status))
    }
}
