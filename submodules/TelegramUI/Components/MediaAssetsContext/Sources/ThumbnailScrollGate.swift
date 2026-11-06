import Foundation
import QuartzCore
import SwiftSignalKit

// Lets the photo grid hold back thumbnail requests while the user flings: a cell that scrolls off screen before its
// image arrives is reused (its signal is disposed and the request cancelled), so the decode is never paid for.
// Main thread only.
public final class ThumbnailScrollGate {
    private var estimator = ScrollVelocityEstimator()
    private let now: () -> Double
    private let makeTimer: (@escaping () -> Void) -> SwiftSignalKit.Timer
    private let waiters = Bag<() -> Void>()
    private var timer: SwiftSignalKit.Timer?

    public init() {
        self.now = { CACurrentMediaTime() }
        self.makeTimer = { completion in
            return SwiftSignalKit.Timer(timeout: 0.1, repeat: true, completion: completion, queue: Queue.mainQueue())
        }
    }

    // For tests: a manual clock and no real timer.
    init(now: @escaping () -> Double, makeTimer: @escaping (@escaping () -> Void) -> SwiftSignalKit.Timer) {
        self.now = now
        self.makeTimer = makeTimer
    }

    deinit {
        self.timer?.invalidate()
    }

    public var isFlinging: Bool {
        return self.estimator.isFlinging(at: self.now())
    }

    // The user touched the grid (a fling was caught) or the scrolling ended: nothing is flying past any more, so
    // held requests start at once instead of waiting for the stale-sample timer.
    public func settle() {
        self.estimator.reset()
        self.releaseIfCalm()
    }

    // Call on every scroll tick with the content offset.
    public func noteOffset(_ offset: Double) {
        self.estimator.note(offset: offset, time: self.now())
        self.releaseIfCalm()
    }

    // Emits once, right away when the grid is calm (so a normal cell setup is unchanged), otherwise when the fling is
    // over. Disposing the signal before then drops the wait.
    public func whenCalm() -> Signal<Void, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putNext(Void())
                subscriber.putCompletion()
                return EmptyDisposable
            }
            if !self.isFlinging {
                subscriber.putNext(Void())
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let index = self.waiters.add({
                subscriber.putNext(Void())
                subscriber.putCompletion()
            })
            self.startTimerIfNeeded()
            return ActionDisposable { [weak self] in
                Queue.mainQueue().async {
                    guard let self else {
                        return
                    }
                    self.waiters.remove(index)
                    self.stopTimerIfIdle()
                }
            }
        }
    }

    // Wraps a request so it only starts once the grid is calm.
    public func deferred<T>(_ signal: Signal<T, NoError>) -> Signal<T, NoError> {
        // Subscribed on the main queue: the gate is main-thread state, and the signal may be started elsewhere
        // (edited photos emit off main).
        return (self.whenCalm() |> runOn(Queue.mainQueue()))
        |> mapToSignal { _ in
            return signal
        }
    }

    private func releaseIfCalm() {
        if self.waiters.isEmpty || self.isFlinging {
            return
        }
        let handlers = self.waiters.copyItems()
        self.waiters.removeAll()
        self.stopTimerIfIdle()
        for handler in handlers {
            handler()
        }
    }

    private func startTimerIfNeeded() {
        if self.timer != nil {
            return
        }
        // The scroll view stops delivering offsets when it stops; the timer notices the stale sample.
        let timer = self.makeTimer { [weak self] in
            self?.releaseIfCalm()
        }
        self.timer = timer
        timer.start()
    }

    private func stopTimerIfIdle() {
        if self.waiters.isEmpty {
            self.timer?.invalidate()
            self.timer = nil
        }
    }
}
