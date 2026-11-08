import Foundation
import SwiftSignalKit

/// The decision logic that stops a client from sending the same server request again and again
/// (owner decision 2026-11-08: reduce how OFTEN a request goes out, never what it says and never
/// what the user sees).
///
/// `RequestCoalescerState` is pure: it holds no clock, no signals and no locks, so it is unit-tested
/// on its own. It answers three questions for a request key:
///
/// 1. Is there a result younger than `lifetime`? Then use it (`.cached`).
/// 2. Is the same request already on its way? Then wait for it (`.joined`) instead of sending a second one.
/// 3. Did the last attempt fail with an answer that says "not before N seconds" (a FLOOD_WAIT)? Then do
///    not ask before that time (`.backedOff`).
///
/// A result is dropped by `invalidate`/`invalidateAll` the moment the caller knows the data behind it
/// changed. A request that was already on its way at that moment keeps serving the callers that were
/// waiting for it, but no caller that comes later joins it and its answer is not remembered, since it
/// may describe the data from before the change.
struct RequestCoalescerState<Key: Hashable, Value> {
    enum Join {
        /// A remembered result that has not expired.
        case cached(Value)
        /// The last attempt asked for a pause that has not elapsed.
        case backedOff
        /// The same request is on its way; the caller was added to the callers waiting for it.
        case joined(flight: Int)
        /// The caller must send the request and report back with `complete(flight:)`.
        case start(flight: Int)
    }

    private struct Flight {
        let key: Key
        let generation: Int
        var waiters: Set<Int>
    }

    private struct Stored {
        let value: Value
        let storedAt: Double
    }

    /// How long a result stays usable, in seconds.
    let lifetime: Double

    private var generation: Int = 0
    private var nextFlight: Int = 0
    private var stored: [Key: Stored] = [:]
    private var backoffUntil: [Key: Double] = [:]
    private var flights: [Int: Flight] = [:]
    private var activeFlight: [Key: Int] = [:]

    init(lifetime: Double) {
        self.lifetime = lifetime
    }

    var storedCount: Int {
        return self.stored.count
    }

    var flightCount: Int {
        return self.flights.count
    }

    mutating func join(key: Key, waiter: Int, now: Double) -> Join {
        if let entry = self.stored[key] {
            if now >= entry.storedAt && now - entry.storedAt < self.lifetime {
                return .cached(entry.value)
            }
            self.stored[key] = nil
        }
        if let until = self.backoffUntil[key] {
            if now < until {
                return .backedOff
            }
            self.backoffUntil[key] = nil
        }
        if let id = self.activeFlight[key], var flight = self.flights[id], flight.generation == self.generation {
            flight.waiters.insert(waiter)
            self.flights[id] = flight
            return .joined(flight: id)
        }
        let id = self.nextFlight
        self.nextFlight += 1
        self.flights[id] = Flight(key: key, generation: self.generation, waiters: [waiter])
        self.activeFlight[key] = id
        return .start(flight: id)
    }

    /// A caller no longer wants the answer. Returns true when nobody is left waiting for the flight,
    /// i.e. the request can be cancelled.
    mutating func leave(flight id: Int, waiter: Int) -> Bool {
        guard var flight = self.flights[id] else {
            return false
        }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty {
            self.removeFlight(id)
            return true
        }
        self.flights[id] = flight
        return false
    }

    /// The request finished. `value` is nil when it failed; `retryAfter` is then the pause the server
    /// asked for (0 when it asked for none). Returns the callers to answer.
    mutating func complete(flight id: Int, value: Value?, retryAfter: Double, now: Double) -> Set<Int> {
        guard let flight = self.flights[id] else {
            return []
        }
        self.removeFlight(id)
        if flight.generation == self.generation {
            if let value {
                self.stored[flight.key] = Stored(value: value, storedAt: now)
                self.backoffUntil[flight.key] = nil
                self.pruneExpired(now: now)
            } else if retryAfter > 0 {
                self.backoffUntil[flight.key] = now + retryAfter
            }
        }
        return flight.waiters
    }

    mutating func invalidate(key: Key) {
        self.generation += 1
        self.stored[key] = nil
        self.backoffUntil[key] = nil
    }

    mutating func invalidateAll() {
        self.generation += 1
        self.stored.removeAll()
        self.backoffUntil.removeAll()
    }

    private mutating func removeFlight(_ id: Int) {
        if let flight = self.flights.removeValue(forKey: id), self.activeFlight[flight.key] == id {
            self.activeFlight[flight.key] = nil
        }
    }

    private mutating func pruneExpired(now: Double) {
        let lifetime = self.lifetime
        self.stored = self.stored.filter { now >= $0.value.storedAt && now - $0.value.storedAt < lifetime }
        self.backoffUntil = self.backoffUntil.filter { now < $0.value }
    }
}

/// The seconds a `FLOOD_WAIT_<n>` / `FLOOD_PREMIUM_WAIT_<n>` / `SLOWMODE_WAIT_<n>` error text asks for, 0 for any other text.
func requestCoalescerRetryAfter(errorDescription: String?) -> Double {
    guard let errorDescription, errorDescription.contains("_WAIT_") else {
        return 0
    }
    guard let tail = errorDescription.split(separator: "_").last, let seconds = Int(tail), seconds > 0 else {
        return 0
    }
    return Double(seconds)
}

func requestCoalescerCurrentTime() -> Double {
    return ProcessInfo.processInfo.systemUptime
}

/// `RequestCoalescerState` behind a lock, joined to signals. `signal(key:fallback:fetch:)` returns the
/// remembered result, or shares one running `fetch` between all callers asking for the same key.
/// `fetch` yields nil when the request failed: that is answered with `fallback` and never remembered.
final class RequestCoalescer<Key: Hashable, Value> {
    private struct Guarded {
        var state: RequestCoalescerState<Key, Value>
        var nextWaiter: Int = 0
        var callbacks: [Int: (Value) -> Void] = [:]
        var fetches: [Int: Disposable] = [:]
    }

    private let guarded: Atomic<Guarded>
    private let now: () -> Double

    init(lifetime: Double, now: @escaping () -> Double = requestCoalescerCurrentTime) {
        self.guarded = Atomic(value: Guarded(state: RequestCoalescerState(lifetime: lifetime)))
        self.now = now
    }

    func invalidate(key: Key) {
        let _ = self.guarded.modify { guarded in
            var guarded = guarded
            guarded.state.invalidate(key: key)
            return guarded
        }
    }

    func invalidateAll() {
        let _ = self.guarded.modify { guarded in
            var guarded = guarded
            guarded.state.invalidateAll()
            return guarded
        }
    }

    /// `retryAfter` reads the pause a failed fetch asked for; `fetch` reports the failure as nil and the pause through it.
    func signal(key: Key, fallback: Value, fetch: Signal<(value: Value?, retryAfter: Double), NoError>) -> Signal<Value, NoError> {
        return Signal { subscriber in
            let now = self.now()
            var outcome: RequestCoalescerState<Key, Value>.Join = .backedOff
            var waiter = 0
            let _ = self.guarded.modify { guarded in
                var guarded = guarded
                waiter = guarded.nextWaiter
                guarded.nextWaiter += 1
                outcome = guarded.state.join(key: key, waiter: waiter, now: now)
                switch outcome {
                case .joined, .start:
                    guarded.callbacks[waiter] = { value in
                        subscriber.putNext(value)
                        subscriber.putCompletion()
                    }
                case .cached, .backedOff:
                    break
                }
                return guarded
            }

            switch outcome {
            case let .cached(value):
                subscriber.putNext(value)
                subscriber.putCompletion()
                return EmptyDisposable
            case .backedOff:
                subscriber.putNext(fallback)
                subscriber.putCompletion()
                return EmptyDisposable
            case let .start(flight):
                let disposable = fetch.start(next: { [weak self] result in
                    self?.finish(flight: flight, value: result.value, retryAfter: result.retryAfter, fallback: fallback)
                }, completed: { [weak self] in
                    // A fetch that ends without an answer counts as a failure; a no-op after an answer.
                    self?.finish(flight: flight, value: nil, retryAfter: 0, fallback: fallback)
                })
                let stillRunning = self.guarded.modify { guarded in
                    var guarded = guarded
                    if guarded.callbacks[waiter] != nil {
                        guarded.fetches[flight] = disposable
                    }
                    return guarded
                }.fetches[flight] != nil
                if !stillRunning {
                    disposable.dispose()
                }
                return self.leaveDisposable(flight: flight, waiter: waiter)
            case let .joined(flight):
                return self.leaveDisposable(flight: flight, waiter: waiter)
            }
        }
    }

    private func leaveDisposable(flight: Int, waiter: Int) -> Disposable {
        return ActionDisposable { [weak self] in
            guard let self else {
                return
            }
            var toDispose: Disposable?
            let _ = self.guarded.modify { guarded in
                var guarded = guarded
                guarded.callbacks[waiter] = nil
                if guarded.state.leave(flight: flight, waiter: waiter) {
                    toDispose = guarded.fetches.removeValue(forKey: flight)
                }
                return guarded
            }
            toDispose?.dispose()
        }
    }

    private func finish(flight: Int, value: Value?, retryAfter: Double, fallback: Value) {
        let now = self.now()
        var deliveries: [(Value) -> Void] = []
        let _ = self.guarded.modify { guarded in
            var guarded = guarded
            let waiters = guarded.state.complete(flight: flight, value: value, retryAfter: retryAfter, now: now)
            guarded.fetches[flight] = nil
            for waiter in waiters {
                if let callback = guarded.callbacks.removeValue(forKey: waiter) {
                    deliveries.append(callback)
                }
            }
            return guarded
        }
        for delivery in deliveries {
            delivery(value ?? fallback)
        }
    }
}
