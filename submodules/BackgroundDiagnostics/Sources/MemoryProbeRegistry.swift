import Foundation

/// Where the app registers what it can measure about its own memory, cheaply (a counter or a stored size, never a walk
/// of a structure). The log reads the numbers every 30 s and at each entry into the
/// background, so a growing footprint can be tied to the cache or the object that grows.
///
/// Thread-safe. A probe runs on whichever thread asks for a snapshot, so it must read only values that are safe to read
/// there (an atomic, a lock-protected counter, a count kept in step by its owner).
public final class MemoryProbeRegistry: @unchecked Sendable {
    public static let shared = MemoryProbeRegistry()

    public struct Reading: Sendable, Equatable {
        public var count: Int
        public var bytes: UInt64?

        public init(count: Int, bytes: UInt64? = nil) {
            self.count = count
            self.bytes = bytes
        }
    }

    /// One name in a snapshot. Several owners that registered under the same name (one chat screen each) are added up.
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var instances: Int
        public var count: Int
        public var bytes: UInt64?

        public init(name: String, instances: Int, count: Int, bytes: UInt64?) {
            self.name = name
            self.instances = instances
            self.count = count
            self.bytes = bytes
        }
    }

    /// Keeps a probe registered. Unregisters when released, so an owner stores it next to what it measures.
    public final class Registration: Sendable {
        private let registry: MemoryProbeRegistry
        private let id: Int

        fileprivate init(registry: MemoryProbeRegistry, id: Int) {
            self.registry = registry
            self.id = id
        }

        deinit {
            self.registry.remove(id: self.id)
        }
    }

    private struct Probe {
        let name: String
        let read: @Sendable () -> Reading
    }

    private let lock = NSLock()
    private var nextId = 0
    private var probes: [Int: Probe] = [:]
    private var live: [String: Int] = [:]

    public init() {
    }

    public func register(name: String, read: @escaping @Sendable () -> Reading) -> Registration {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        let id = self.nextId
        self.nextId += 1
        self.probes[id] = Probe(name: name, read: read)
        return Registration(registry: self, id: id)
    }

    /// Counts a live object of kind `name` (see `LiveInstanceToken`).
    func adjustLive(name: String, by delta: Int) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        let value = (self.live[name] ?? 0) + delta
        if value > 0 {
            self.live[name] = value
        } else {
            self.live.removeValue(forKey: name)
        }
    }

    fileprivate func remove(id: Int) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.probes.removeValue(forKey: id)
    }

    /// Entries by name, probes first. Probes run outside the lock.
    public func snapshot() -> (caches: [Entry], instances: [Entry]) {
        self.lock.lock()
        let probes = Array(self.probes.values)
        let live = self.live
        self.lock.unlock()

        var byName: [String: Entry] = [:]
        for probe in probes {
            let reading = probe.read()
            var entry = byName[probe.name] ?? Entry(name: probe.name, instances: 0, count: 0, bytes: nil)
            entry.instances += 1
            entry.count += reading.count
            if let bytes = reading.bytes {
                entry.bytes = (entry.bytes ?? 0) + bytes
            }
            byName[probe.name] = entry
        }
        let caches = byName.values.sorted { $0.name < $1.name }
        let instances = live.map { Entry(name: $0.key, instances: $0.value, count: $0.value, bytes: nil) }.sorted { $0.name < $1.name }
        return (caches, instances)
    }
}

/// Counts one live object of a kind for as long as the token lives: store it as a property of the object
/// (`private let liveToken = LiveInstanceToken("ChatControllerNode")`). A kind whose count only goes up has instances
/// something keeps alive.
public final class LiveInstanceToken: Sendable {
    private let registry: MemoryProbeRegistry
    private let name: String

    public init(_ name: String, registry: MemoryProbeRegistry = .shared) {
        self.registry = registry
        self.name = name
        registry.adjustLive(name: name, by: 1)
    }

    deinit {
        self.registry.adjustLive(name: self.name, by: -1)
    }
}
