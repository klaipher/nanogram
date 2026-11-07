import Foundation
import UIKit

/// Accessibility-only work of list rows (labels and values built from message text) that used to run
/// inside each row's layout, on the main thread in scroll frames. Requests are coalesced per owner and
/// run once no new request arrived for `quietInterval` (rows stopped arriving), a batch per run loop
/// turn. Owners are held weakly, so rows that left the list cost nothing. While VoiceOver or Switch
/// Control is on, requests run at once: they read rows during scrolling.
public final class ListViewDeferredAccessibility {
    public static let shared = ListViewDeferredAccessibility(quietInterval: 0.25, batchSize: 6, isImmediate: {
        return UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    })

    private final class Entry {
        weak var owner: AnyObject?
        var action: () -> Void

        init(owner: AnyObject, action: @escaping () -> Void) {
            self.owner = owner
            self.action = action
        }
    }

    /// Debug Settings ▸ "List rows: accessibility text at once" (off by default): build the strings inside each row's
    /// layout, as upstream does, to compare scroll smoothness. Main thread.
    public var forcesImmediate: Bool = false

    private let quietInterval: Double
    private let batchSize: Int
    private let isImmediate: () -> Bool

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var order: [ObjectIdentifier] = []
    private var lastRequestTime: Double = 0.0
    private var timer: Foundation.Timer?

    init(quietInterval: Double, batchSize: Int, isImmediate: @escaping () -> Bool) {
        self.quietInterval = quietInterval
        self.batchSize = max(1, batchSize)
        self.isImmediate = isImmediate
    }

    /// Main thread only. `action` should capture `owner` weakly; a later request for the same owner
    /// replaces it.
    public func request(owner: AnyObject, _ action: @escaping () -> Void) {
        let id = ObjectIdentifier(owner)
        if self.forcesImmediate || self.isImmediate() {
            self.entries.removeValue(forKey: id)
            action()
            return
        }
        if let entry = self.entries[id] {
            // The identifier can be reused by a new object once the old one is gone.
            entry.owner = owner
            entry.action = action
        } else {
            self.entries[id] = Entry(owner: owner, action: action)
            self.order.append(id)
        }
        self.lastRequestTime = CACurrentMediaTime()
        if self.timer == nil {
            self.arm(after: self.quietInterval)
        }
    }

    private func arm(after delay: Double) {
        let timer = Foundation.Timer(timeInterval: max(0.0, delay), repeats: false, block: { [weak self] _ in
            self?.timerFired()
        })
        // Common modes: also fire while a finger rests on a scroll view.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func timerFired() {
        self.timer = nil
        let sinceLastRequest = CACurrentMediaTime() - self.lastRequestTime
        if sinceLastRequest < self.quietInterval {
            self.arm(after: self.quietInterval - sinceLastRequest)
            return
        }

        var ran = 0
        while ran < self.batchSize, !self.order.isEmpty {
            let id = self.order.removeFirst()
            guard let entry = self.entries.removeValue(forKey: id) else {
                continue
            }
            if entry.owner != nil {
                entry.action()
                ran += 1
            }
        }
        if !self.order.isEmpty {
            // The rest on the next run loop turn, so one turn stays short.
            self.arm(after: 0.0)
        }
    }
}
