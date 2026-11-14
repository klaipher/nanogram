import Foundation
import SwiftSignalKit

/// The playback status of one node. A node publishes it on every frame, so while nobody observes `signal`
/// the latest value is only remembered (main queue). A new subscriber is registered on the main queue and
/// first receives that latest value, so it never sees a status left over from an unobserved stretch.
final class AnimatedStickerStatusPublisher {
    private final class Subscriber {
        let deliver: (AnimatedStickerStatus) -> Void
        var hasReceived: Bool = false

        init(deliver: @escaping (AnimatedStickerStatus) -> Void) {
            self.deliver = deliver
        }
    }

    private let subscriberCount = Atomic<Int>(value: 0)
    private let subscribers = Bag<Subscriber>()
    private var latest: AnimatedStickerStatus?
    private(set) var deliveryCount: Int = 0

    var hasSubscribers: Bool {
        return self.subscriberCount.with { $0 } > 0
    }

    var signal: Signal<AnimatedStickerStatus, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                return EmptyDisposable
            }
            let _ = self.subscriberCount.modify { $0 + 1 }
            let entry = Subscriber(deliver: { status in
                subscriber.putNext(status)
            })
            let disposed = Atomic<Bool>(value: false)
            let index = Atomic<Bag<Subscriber>.Index?>(value: nil)
            Queue.mainQueue().async { [weak self] in
                guard let self, !disposed.with({ $0 }) else {
                    return
                }
                let _ = index.modify { _ in self.subscribers.add(entry) }
                if !entry.hasReceived, let latest = self.latest {
                    entry.hasReceived = true
                    self.deliveryCount += 1
                    entry.deliver(latest)
                }
            }
            return ActionDisposable { [weak self] in
                let _ = disposed.modify { _ in true }
                let _ = self?.subscriberCount.modify { $0 - 1 }
                Queue.mainQueue().async {
                    if let self, let index = index.with({ $0 }) {
                        self.subscribers.remove(index)
                    }
                }
            }
        }
    }

    /// Main queue only.
    func publish(_ status: AnimatedStickerStatus) {
        self.latest = status
        guard self.hasSubscribers else {
            return
        }
        let entries = self.subscribers.copyItems()
        if entries.isEmpty {
            return
        }
        self.deliveryCount += 1
        for entry in entries {
            entry.hasReceived = true
            entry.deliver(status)
        }
    }
}
