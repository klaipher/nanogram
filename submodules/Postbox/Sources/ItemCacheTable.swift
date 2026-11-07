import Foundation

public final class ItemCacheEntryId: Equatable, Hashable {
    public let collectionId: ItemCacheCollectionId
    public let key: ValueBoxKey
    
    public init(collectionId: ItemCacheCollectionId, key: ValueBoxKey) {
        self.collectionId = collectionId
        self.key = key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.collectionId)
        hasher.combine(self.key)
    }

    public static func ==(lhs: ItemCacheEntryId, rhs: ItemCacheEntryId) -> Bool {
        return lhs.collectionId == rhs.collectionId && lhs.key == rhs.key
    }
}

private enum ItemCacheSection: Int8 {
    case items = 0
    case accessIndexToItemId = 1
    case itemIdToAccessIndex = 2
}

final class ItemCacheTable: Table {
    static func tableSpec(_ id: Int32) -> ValueBoxTable {
        return ValueBoxTable(id: id, keyType: .binary, compactValuesOnCreation: false)
    }
    
    private func itemKey(id: ItemCacheEntryId) -> ValueBoxKey {
        let key = ValueBoxKey(length: 1 + 1 + id.key.length)
        key.setInt8(0, value: ItemCacheSection.items.rawValue)
        key.setInt8(1, value: id.collectionId)
        memcpy(key.memory.advanced(by: 2), id.key.memory, id.key.length)
        return key
    }
    
    private func lowerBound(collectionId: ItemCacheCollectionId) -> ValueBoxKey {
        let key = ValueBoxKey(length: 1 + 1)
        key.setInt8(0, value: ItemCacheSection.items.rawValue)
        key.setInt8(1, value: collectionId)
        return key
    }
    
    private func upperBound(collectionId: ItemCacheCollectionId) -> ValueBoxKey {
        return self.lowerBound(collectionId: collectionId).successor
    }
    
    private func itemIdToAccessIndexKey(id: ItemCacheEntryId) -> ValueBoxKey {
        let key = ValueBoxKey(length: 1 + 1 + id.key.length)
        key.setInt8(0, value: ItemCacheSection.accessIndexToItemId.rawValue)
        key.setInt8(1, value: id.collectionId)
        memcpy(key.memory.advanced(by: 2), id.key.memory, id.key.length)
        return key
    }
    
    private func accessIndexToItemId(collectionId: ItemCacheCollectionId, index: Int32) -> ValueBoxKey {
        let key = ValueBoxKey(length: 1 + 1 + 4)
        key.setInt8(0, value: ItemCacheSection.accessIndexToItemId.rawValue)
        key.setInt8(1, value: collectionId)
        key.setInt32(2, value: index)
        return key
    }

    /// Stores `entry`. Returns false, and writes nothing, when the stored bytes are already exactly these (a
    /// cache refreshed with the same answer): the row stays as it is and the caller reports no change.
    @discardableResult
    func put(id: ItemCacheEntryId, entry: CodableEntry, metaTable: ItemCacheMetaTable) -> Bool {
        let key = self.itemKey(id: id)
        if let current = self.valueBox.get(self.table, key: key), current.length == entry.data.count {
            let isIdentical = entry.data.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else {
                    return true
                }
                return memcmp(current.memory, base, current.length) == 0
            }
            if isIdentical {
                return false
            }
        }
        self.valueBox.set(self.table, key: key, value: ReadBuffer(data: entry.data))
        return true
    }

    func retrieve(id: ItemCacheEntryId, metaTable: ItemCacheMetaTable) -> CodableEntry? {
        if let value = self.valueBox.get(self.table, key: self.itemKey(id: id)) {
            return CodableEntry(data: value.makeData())
        }
        return nil
    }
    
    func remove(id: ItemCacheEntryId, metaTable: ItemCacheMetaTable) {
        self.valueBox.remove(self.table, key: self.itemKey(id: id), secure: false)
    }
    
    func removeAll(collectionId: ItemCacheCollectionId) {
        self.valueBox.removeRange(self.table, start: self.lowerBound(collectionId: collectionId), end: self.upperBound(collectionId: collectionId))
    }
    
    override func clearMemoryCache() {
        
    }
    
    override func beforeCommit() {
        
    }
}
