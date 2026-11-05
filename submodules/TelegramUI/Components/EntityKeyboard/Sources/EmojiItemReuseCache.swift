import Foundation

// Keeps the values built by the previous pass of a rebuild loop, so the next pass hands out the same instances for
// entries that did not change. The emoji panel rebuilds every item of every installed pack whenever any of its inputs
// emits (384,445 items over 52 rebuilds in one recording); a reused item also makes the later `===` shortcut in
// `Item.==` hit, so comparing two panel contents does not walk the items.
//
// An entry is reused only when its fingerprint is equal, so a changed file, icon or tint builds a new value. Only the
// last pass is kept: entries that a pass did not ask for are dropped when it is committed.
final class EmojiItemReuseCache<Key: Hashable, Fingerprint: Equatable, Value> {
    struct Entry {
        let fingerprint: Fingerprint
        let value: Value
    }

    struct Pass {
        private let previous: [Key: Entry]
        private var next: [Key: Entry] = [:]
        private(set) var reusedCount = 0
        private(set) var builtCount = 0

        fileprivate init(previous: [Key: Entry]) {
            self.previous = previous
            self.next.reserveCapacity(previous.count)
        }

        fileprivate var entries: [Key: Entry] {
            return self.next
        }

        mutating func value(for key: Key, fingerprint: Fingerprint, make: () -> Value) -> Value {
            if let entry = self.next[key], entry.fingerprint == fingerprint {
                // The same key twice in a pass (a duplicate entry): share the value.
                self.reusedCount += 1
                return entry.value
            }
            if let entry = self.previous[key], entry.fingerprint == fingerprint {
                self.next[key] = entry
                self.reusedCount += 1
                return entry.value
            }
            let value = make()
            self.next[key] = Entry(fingerprint: fingerprint, value: value)
            self.builtCount += 1
            return value
        }
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    func beginPass() -> Pass {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return Pass(previous: self.entries)
    }

    func commit(_ pass: Pass) {
        let entries = pass.entries
        self.lock.lock()
        self.entries = entries
        self.lock.unlock()
    }

    var count: Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.entries.count
    }
}
