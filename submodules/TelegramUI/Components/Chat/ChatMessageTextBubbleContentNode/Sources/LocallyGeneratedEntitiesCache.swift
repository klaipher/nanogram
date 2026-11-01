import Foundation
import TelegramCore
import TextFormat

/// Results of `addLocallyGeneratedEntities` (data-detector phone numbers, timecodes) shared by every
/// text bubble. A node keeps its own last result, but CoreList builds a new node for each row that
/// scrolls back into the window, so without this the detector ran again on every re-entry.
final class LocallyGeneratedEntitiesCache {
    static let shared = LocallyGeneratedEntitiesCache(capacity: 256)

    private struct Key: Hashable {
        let text: String
        let entities: [MessageTextEntity]
        let enabledTypes: Int32
        let mediaDuration: Double?

        static func ==(lhs: Key, rhs: Key) -> Bool {
            return lhs.enabledTypes == rhs.enabledTypes && lhs.mediaDuration == rhs.mediaDuration && lhs.text == rhs.text && lhs.entities == rhs.entities
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.text)
            hasher.combine(self.entities.count)
            hasher.combine(self.enabledTypes)
            hasher.combine(self.mediaDuration)
        }
    }

    private final class Value {
        let entities: [MessageTextEntity]?
        init(_ entities: [MessageTextEntity]?) {
            self.entities = entities
        }
    }

    private let capacity: Int
    private let lock = NSLock()
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.count
    }

    /// Same result as `addLocallyGeneratedEntities` with these arguments. Layouts run on any thread.
    func entities(_ text: String, enabledTypes: EnabledEntityTypes, entities: [MessageTextEntity], mediaDuration: Double?) -> [MessageTextEntity]? {
        let key = Key(text: text, entities: entities, enabledTypes: enabledTypes.rawValue, mediaDuration: mediaDuration)
        self.lock.lock()
        if let value = self.values[key] {
            self.lock.unlock()
            return value.entities
        }
        self.lock.unlock()

        let result = addLocallyGeneratedEntities(text, enabledTypes: enabledTypes, entities: entities, mediaDuration: mediaDuration)

        self.lock.lock()
        if self.values[key] == nil {
            self.values[key] = Value(result)
            self.order.append(key)
            if self.order.count > self.capacity {
                // Oldest first; trim in batches so the array shift is rare.
                let removeCount = self.order.count - self.capacity + self.capacity / 4
                for removed in self.order.prefix(removeCount) {
                    self.values.removeValue(forKey: removed)
                }
                self.order.removeFirst(min(removeCount, self.order.count))
            }
        }
        self.lock.unlock()
        return result
    }
}
