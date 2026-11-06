import Foundation

/// Cancellation flag of one background preparation. The job checks it before it starts and the cache cancels it when
/// the result is no longer wanted. Safe from any thread.
public final class ChatRowPrepTicket {
    private let lock = NSLock()
    private var cancelled = false

    public init() {
    }

    public var isCancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancelled
    }

    public func cancel() {
        self.lock.lock()
        self.cancelled = true
        self.lock.unlock()
    }
}

/// Prepared rows by row identity, valid only for the exact key they were prepared under.
///
/// Main thread only (the background job delivers its result to the main queue before it calls `complete`). The cache
/// never decides what a row looks like: it hands a payload back only for a key that is `==` to the one it was stored
/// under, and a payload that is dropped for any other reason goes to `onDiscard`.
public final class ChatRowPrepCache<Neighbors: Equatable, Payload> {
    public struct Limits {
        /// Rows prepared or being prepared at once.
        public var maxEntries: Int
        /// How long a finished result may wait for its row.
        public var timeToLive: TimeInterval

        public init(maxEntries: Int = 10, timeToLive: TimeInterval = 5.0) {
            self.maxEntries = maxEntries
            self.timeToLive = timeToLive
        }
    }

    public typealias Key = ChatRowPrepKey<Neighbors>

    public enum Claim {
        /// Start the job; deliver the result with `complete`.
        case started(ChatRowPrepTicket)
        /// The same key is already prepared or in flight.
        case alreadyPrepared
        /// At the entry limit.
        case full
    }

    public enum MissReason {
        case nothingPrepared
        case keyMismatch
        case inFlight
        case expired
    }

    public enum Take {
        case hit(Payload)
        case miss(MissReason)
    }

    private enum State {
        case inFlight(ChatRowPrepTicket)
        case ready(Payload, TimeInterval)
    }

    private struct Entry {
        var key: Key
        var state: State
    }

    public let limits: Limits
    private let now: () -> TimeInterval
    private var entries: [UInt64: Entry] = [:]
    /// Called for every ready payload that leaves the cache without being taken.
    public var onDiscard: ((Payload) -> Void)?

    public init(limits: Limits = Limits(), now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.limits = limits
        self.now = now
    }

    public var count: Int {
        return self.entries.count
    }

    public var inFlightCount: Int {
        return self.entries.values.filter { entry in
            if case .inFlight = entry.state {
                return true
            }
            return false
        }.count
    }

    public func claim(_ key: Key) -> Claim {
        if let entry = self.entries[key.stableId] {
            if entry.key == key {
                return .alreadyPrepared
            }
            self.remove(key.stableId)
        }
        if self.entries.count >= self.limits.maxEntries {
            return .full
        }
        let ticket = ChatRowPrepTicket()
        self.entries[key.stableId] = Entry(key: key, state: .inFlight(ticket))
        return .started(ticket)
    }

    /// Stores a finished result. Returns false, and discards the payload, when the claim no longer exists (cancelled,
    /// evicted, replaced, or the row was already built synchronously).
    @discardableResult
    public func complete(ticket: ChatRowPrepTicket, key: Key, payload: Payload) -> Bool {
        guard !ticket.isCancelled, let entry = self.entries[key.stableId], entry.key == key, case let .inFlight(current) = entry.state, current === ticket else {
            self.onDiscard?(payload)
            return false
        }
        self.entries[key.stableId] = Entry(key: key, state: .ready(payload, self.now()))
        return true
    }

    /// The job produced nothing (cancelled before it ran, or the item has no synchronous node).
    public func fail(ticket: ChatRowPrepTicket, key: Key) {
        if let entry = self.entries[key.stableId], entry.key == key, case let .inFlight(current) = entry.state, current === ticket {
            self.entries.removeValue(forKey: key.stableId)
        }
    }

    /// The prepared payload for exactly `key`, removed from the cache. Anything else is a miss, and a prepared result
    /// under a different key is dropped on the spot (it can never match again: the row's inputs moved on).
    public func take(_ key: Key) -> Take {
        guard let entry = self.entries[key.stableId] else {
            return .miss(.nothingPrepared)
        }
        guard entry.key == key else {
            self.remove(key.stableId)
            return .miss(.keyMismatch)
        }
        switch entry.state {
        case .inFlight:
            // The row is built synchronously now; the late result would be unused.
            self.remove(key.stableId)
            return .miss(.inFlight)
        case let .ready(payload, readyAt):
            self.entries.removeValue(forKey: key.stableId)
            if self.now() - readyAt > self.limits.timeToLive {
                self.onDiscard?(payload)
                return .miss(.expired)
            }
            return .hit(payload)
        }
    }

    /// Keeps only the entries whose key is in `keys`; cancels and discards the rest. Called on every planning round with
    /// the keys of the rows that are about to enter the band, so rows that left it, a new width, theme, font size,
    /// neighbours or a replaced item all evict.
    public func retain(keys: [Key]) {
        var stale: [UInt64] = []
        for (stableId, entry) in self.entries {
            if !keys.contains(where: { $0 == entry.key }) {
                stale.append(stableId)
            }
        }
        for stableId in stale {
            self.remove(stableId)
        }
    }

    public func evictAll() {
        for stableId in Array(self.entries.keys) {
            self.remove(stableId)
        }
    }

    private func remove(_ stableId: UInt64) {
        guard let entry = self.entries.removeValue(forKey: stableId) else {
            return
        }
        switch entry.state {
        case let .inFlight(ticket):
            ticket.cancel()
        case let .ready(payload, _):
            self.onDiscard?(payload)
        }
    }
}
