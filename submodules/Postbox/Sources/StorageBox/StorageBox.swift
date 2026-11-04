import Foundation
import SwiftSignalKit
import CryptoUtils

public struct HashId: Hashable {
    public let data: Data
    
    public init(data: Data) {
        precondition(data.count == 16)
        self.data = data
    }
}

private func md5Hash(_ data: Data) -> HashId {
    let hashData = data.withUnsafeBytes { bytes -> Data in
        return CryptoMD5(bytes.baseAddress!, Int32(bytes.count))
    }
    return HashId(data: hashData)
}

public var storageBoxDebugFunc: ((Int64) -> Void)?

/// Registrations (`add` without a size) this connection has stored: item id → content type and
/// the references seen with it. Two generations of `capacity` ids each: when the current one is
/// full it becomes the previous one, and a hit in the previous one moves back.
private struct StorageBoxRegistrationCache {
    private struct Entry {
        var contentType: UInt8
        var references: [StorageBox.Reference]
    }
    
    private static let maxReferencesPerId = 8
    
    private let capacity: Int
    private var current: [Data: Entry] = [:]
    private var previous: [Data: Entry] = [:]
    
    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }
    
    var count: Int {
        return self.current.count + self.previous.count
    }
    
    private static func isSame(_ lhs: StorageBox.Reference, _ rhs: StorageBox.Reference) -> Bool {
        return lhs.peerId == rhs.peerId && lhs.messageNamespace == rhs.messageNamespace && lhs.messageId == rhs.messageId
    }
    
    mutating func contains(id: Data, reference: StorageBox.Reference, contentType: UInt8) -> Bool {
        var entry: Entry
        if let value = self.current[id] {
            entry = value
        } else if let value = self.previous.removeValue(forKey: id) {
            entry = value
            self.insert(id: id, entry: entry)
        } else {
            return false
        }
        if entry.contentType != contentType {
            return false
        }
        return entry.references.contains(where: { StorageBoxRegistrationCache.isSame($0, reference) })
    }
    
    mutating func record(id: Data, reference: StorageBox.Reference, contentType: UInt8) {
        if self.capacity == 0 {
            return
        }
        var entry = self.current.removeValue(forKey: id) ?? self.previous.removeValue(forKey: id) ?? Entry(contentType: contentType, references: [])
        // A different type replaced the stored one for every reference.
        if entry.contentType != contentType {
            entry = Entry(contentType: contentType, references: [])
        }
        if !entry.references.contains(where: { StorageBoxRegistrationCache.isSame($0, reference) }) {
            if entry.references.count >= StorageBoxRegistrationCache.maxReferencesPerId {
                entry.references.removeFirst()
            }
            entry.references.append(reference)
        }
        self.insert(id: id, entry: entry)
    }
    
    mutating func forget(id: Data) {
        self.current.removeValue(forKey: id)
        self.previous.removeValue(forKey: id)
    }
    
    mutating func forgetAll() {
        self.current.removeAll()
        self.previous.removeAll()
    }
    
    private mutating func insert(id: Data, entry: Entry) {
        if self.current.count >= self.capacity {
            self.previous = self.current
            self.current = [:]
        }
        self.current[id] = entry
    }
}

public final class StorageBox {
    public final class Stats {
        public final class ContentTypeStats {
            public fileprivate(set) var size: Int64
            public fileprivate(set) var messages: [MessageId: Int64]
            
            init(size: Int64, messages: [MessageId: Int64]) {
                self.size = size
                self.messages = messages
            }
        }
        
        public fileprivate(set) var contentTypes: [UInt8: ContentTypeStats]
        
        public init(contentTypes: [UInt8: ContentTypeStats]) {
            self.contentTypes = contentTypes
        }
    }
    
    public final class AllStats {
        public fileprivate(set) var total: Stats
        public fileprivate(set) var peers: [PeerId: Stats]
        
        public init(total: Stats, peers: [PeerId: Stats]) {
            self.total = total
            self.peers = peers
        }
    }
    
    public struct Reference {
        public var peerId: Int64
        public var messageNamespace: UInt8
        public var messageId: Int32
        
        public init(peerId: Int64, messageNamespace: UInt8, messageId: Int32) {
            self.peerId = peerId
            self.messageNamespace = messageNamespace
            self.messageId = messageId
        }
    }
    
    public final class Entry {
        public let id: Data
        public let references: [Reference]
        
        init(id: Data, references: [Reference]) {
            self.id = id
            self.references = references
        }
    }
    
    public final class Logger {
        private let impl: (String) -> Void
        
        public init(impl: @escaping (String) -> Void) {
            self.impl = impl
        }
        
        func log(_ string: @autoclosure () -> String) {
            self.impl(string())
        }
    }
    
    private struct ItemInfo {
        var id: Data
        var contentType: UInt8
        var size: Int64
        
        init(id: Data, contentType: UInt8, size: Int64) {
            self.id = id
            self.contentType = contentType
            self.size = size
        }
        
        init(buffer: MemoryBuffer) {
            var id = Data()
            var contentType: UInt8 = 0
            var size: Int64 = 0
            
            withExtendedLifetime(buffer, {
                let readBuffer = ReadBuffer(memoryBufferNoCopy: buffer)
                var version: UInt8 = 0
                readBuffer.read(&version, offset: 0, length: 1)
                let _ = version
                
                var idLength: UInt16 = 0
                readBuffer.read(&idLength, offset: 0, length: 2)
                id.count = Int(idLength)
                id.withUnsafeMutableBytes { buffer -> Void in
                    readBuffer.read(buffer.baseAddress!, offset: 0, length: buffer.count)
                }
                
                readBuffer.read(&contentType, offset: 0, length: 1)
                
                readBuffer.read(&size, offset: 0, length: 8)
            })
            
            self.id = id
            self.contentType = contentType
            self.size = size
        }
        
        func serialize() -> MemoryBuffer {
            let writeBuffer = WriteBuffer()
            
            var version: UInt8 = 0
            writeBuffer.write(&version, length: 1)
            
            var idLength = UInt16(clamping: self.id.count)
            writeBuffer.write(&idLength, length: 2)
            self.id.withUnsafeBytes { buffer in
                writeBuffer.write(buffer.baseAddress!, length: Int(idLength))
            }
            
            var contentType = self.contentType
            writeBuffer.write(&contentType, length: 1)
            
            var size = self.size
            writeBuffer.write(&size, length: 8)
            
            return writeBuffer
        }
    }
    
    private struct Metadata: Codable {
        var version: Int32
    }
    
    private final class Impl {
        let queue: Queue
        let logger: StorageBox.Logger
        let basePath: String
        let valueBox: SqliteValueBox
        let hashIdToInfoTable: ValueBoxTable
        let idToReferenceTable: ValueBoxTable
        let peerIdToIdTable: ValueBoxTable
        let peerContentTypeStatsTable: ValueBoxTable
        let contentTypeStatsTable: ValueBoxTable
        let metadataTable: ValueBoxTable
        
        let totalSizeSubscribers = Bag<(Int64) -> Void>()
        private var totalSize: Int64 = 0
        
        private var queuedInternalTransactions = Atomic<[() -> Void]>(value: [])
        
        // For tests.
        private(set) var transactionCount = 0
        private(set) var appliedSizeUpdateCount = 0
        
        // MediaBox calls `add` on every request of a file that is not complete yet, and most calls
        // repeat a stored registration, which writes nothing but still costs a write transaction.
        // Those are answered from here. Every operation that can undo a registration forgets the
        // ids it touches, both when called and when it runs (it may be queued while suspended).
        private var registrations = StorageBoxRegistrationCache(capacity: StorageBox.registrationCacheCapacity)
        
        var registrationCacheCount: Int {
            return self.registrations.count
        }
        
        init(queue: Queue, logger: StorageBox.Logger, basePath: String, isMainProcess: Bool) {
            self.queue = queue
            self.logger = logger
            self.basePath = basePath
            
            let databasePath = self.basePath + "/db"
            let _ = try? FileManager.default.createDirectory(atPath: databasePath, withIntermediateDirectories: true)
            
            // The index is disposable: the database never traps (`isDisposable`). A file that
            // cannot be opened is not deleted here, since locked or protected-data-unavailable
            // files fail too; SqliteValueBox replaces a corrupt or repeatedly unopenable one
            // itself. Without the file, this launch keeps the index in memory and the next open
            // tries the file again.
            var valueBox: SqliteValueBox?
            for i in 0 ..< 3 {
                if let valueBoxValue = SqliteValueBox(basePath: databasePath, queue: queue, isTemporary: false, isReadOnly: false, useCaches: isMainProcess, removeDatabaseOnError: isMainProcess, encryptionParameters: nil, upgradeProgress: { _ in }, isDisposable: true) {
                    valueBox = valueBoxValue
                    break
                } else {
                    postboxLog("Could not open value box at \(databasePath) (try \(i))")
                    
                    Thread.sleep(forTimeInterval: 0.1 + 0.5 * Double(i))
                }
            }
            
            if valueBox == nil {
                postboxLog("Could not open value box at \(databasePath), keeping the index in memory until the next launch")
                valueBox = SqliteValueBox(basePath: databasePath, queue: queue, isTemporary: true, isReadOnly: false, useCaches: isMainProcess, removeDatabaseOnError: false, encryptionParameters: nil, upgradeProgress: { _ in }, inMemory: true, isDisposable: true)
            }
            
            guard let valueBox = valueBox else {
                // Only when SQLite cannot even allocate an in-memory database.
                postboxLog("Giving up on opening value box at \(databasePath)")
                postboxLogSync()
                preconditionFailure("StorageBox: no database, not even in memory")
            }
            self.valueBox = valueBox
            
            self.hashIdToInfoTable = ValueBoxTable(id: 15, keyType: .binary, compactValuesOnCreation: true)
            self.idToReferenceTable = ValueBoxTable(id: 16, keyType: .binary, compactValuesOnCreation: true)
            self.peerIdToIdTable = ValueBoxTable(id: 17, keyType: .binary, compactValuesOnCreation: true)
            self.peerContentTypeStatsTable = ValueBoxTable(id: 19, keyType: .binary, compactValuesOnCreation: true)
            self.contentTypeStatsTable = ValueBoxTable(id: 20, keyType: .binary, compactValuesOnCreation: true)
            self.metadataTable = ValueBoxTable(id: 21, keyType: .binary, compactValuesOnCreation: true)
            
            self.performUpdatesIfNeeded()
            
            self.updateTotalSize()
        }
        
        private func performUpdatesIfNeeded() {
            self.beginInternalTransaction {
                // Without a transaction a reindex could stop half way; the version stays old, so
                // the next open reindexes.
                if !self.valueBox.tryBegin() {
                    self.logger.log("StorageBox: could not begin the reindex transaction, retrying on the next open")
                    return
                }
                
                let mainMetadataKey = ValueBoxKey(length: 2)
                mainMetadataKey.setUInt8(0, value: 0)
                mainMetadataKey.setUInt8(1, value: 0)
                
                var metadata: Metadata
                if let value = self.valueBox.get(self.metadataTable, key: mainMetadataKey), let parsedValue = try? JSONDecoder().decode(Metadata.self, from: value.makeData()) {
                    metadata = parsedValue
                } else {
                    metadata = Metadata(version: 0)
                }
                
                if metadata.version != 2 {
                    self.reindexPeerStats()
                    
                    metadata.version = 2
                    if let data = try? JSONEncoder().encode(metadata) {
                        self.valueBox.set(self.metadataTable, key: mainMetadataKey, value: MemoryBuffer(data: data))
                    }
                }
                
                self.valueBox.commit()
            }
        }
        
        private func reindexPeerStats() {
            self.valueBox.removeAllFromTable(self.peerContentTypeStatsTable)
            
            let mainKey = ValueBoxKey(length: 16)
            self.valueBox.scan(self.peerIdToIdTable, keys: { key in
                let peerId = key.getInt64(0)
                let hashId = key.getData(8, length: 16)
                
                mainKey.setData(0, value: hashId)
                
                if let currentInfoValue = self.valueBox.get(self.hashIdToInfoTable, key: mainKey) {
                    let info = ItemInfo(buffer: currentInfoValue)
                    self.internalAddSize(peerId: peerId, contentType: info.contentType, delta: info.size)
                }
                
                return true
            })
        }
        
        func updateTotalSize() {
            self.beginInternalTransaction {
                self.valueBox.begin()
                
                var totalSize: Int64 = 0
                self.valueBox.scan(self.contentTypeStatsTable, values: { key, value in
                    var size: Int64 = 0
                    value.read(&size, offset: 0, length: 8)
                    totalSize += size
                    
                    return true
                })
                
                self.valueBox.commit()
                
                if self.totalSize != totalSize {
                    self.totalSize = totalSize
                    
                    for f in self.totalSizeSubscribers.copyItems() {
                        f(totalSize)
                    }
                }
            }
        }
        
        func incrementalUpdateTotalSize() {
            for f in self.totalSizeSubscribers.copyItems() {
                f(totalSize)
            }
        }
        
        func reset() {
            self.registrations.forgetAll()
            self.beginInternalTransaction {
                self.registrations.forgetAll()
                self.valueBox.begin()
                
                self.valueBox.removeAllFromTable(self.hashIdToInfoTable)
                self.valueBox.removeAllFromTable(self.idToReferenceTable)
                self.valueBox.removeAllFromTable(self.peerIdToIdTable)
                self.valueBox.removeAllFromTable(self.peerContentTypeStatsTable)
                self.valueBox.removeAllFromTable(self.contentTypeStatsTable)
                self.valueBox.removeAllFromTable(self.metadataTable)
                
                self.valueBox.commit()
                
                self.updateTotalSize()
            }
        }
        
        private func internalAddSize(contentType: UInt8, delta: Int64) {
            // A zero delta (every downloaded chunk of a file whose size is already known) would
            // rewrite the same row.
            if delta == 0 {
                return
            }
            let key = ValueBoxKey(length: 1)
            key.setUInt8(0, value: contentType)
            
            var currentSize: Int64 = 0
            if let value = self.valueBox.get(self.contentTypeStatsTable, key: key) {
                value.read(&currentSize, offset: 0, length: 8)
            }
            
            currentSize += delta
            
            if currentSize < 0 {
                //assertionFailure()
                currentSize = 0
            }
            
            withExtendedLifetime(key, {
                withUnsafeMutablePointer(to: &currentSize, { pointer in
                    self.valueBox.set(self.contentTypeStatsTable, key: key, value: MemoryBuffer(memory: UnsafeMutableRawPointer(pointer), capacity: 8, length: 8, freeWhenDone: false))
                })
            })
            
            self.totalSize += delta
        }
        
        private func internalAddSize(peerId: Int64, contentType: UInt8, delta: Int64) {
            if delta == 0 {
                return
            }
            let key = ValueBoxKey(length: 8 + 1)
            key.setInt64(0, value: peerId)
            key.setUInt8(8, value: contentType)
            
            var currentSize: Int64 = 0
            if let value = self.valueBox.get(self.peerContentTypeStatsTable, key: key) {
                value.read(&currentSize, offset: 0, length: 8)
            }
            
            currentSize += delta
            
            if currentSize < 0 {
                //assertionFailure()
                currentSize = 0
            }
            
            withExtendedLifetime(key, {
                withUnsafeMutablePointer(to: &currentSize, { pointer in
                    self.valueBox.set(self.peerContentTypeStatsTable, key: key, value: MemoryBuffer(memory: UnsafeMutableRawPointer(pointer), capacity: 8, length: 8, freeWhenDone: false))
                })
            })
        }
        
        func internalAdd(reference: Reference, to id: Data, contentType: UInt8, size: Int64?) {
            let hashId = md5Hash(id)
            
            let mainKey = ValueBoxKey(length: 16)
            mainKey.setData(0, value: hashId.data)
            
            var previousContentType: UInt8?
            var previousSize: Int64 = 0
            if let currentInfoValue = self.valueBox.get(self.hashIdToInfoTable, key: mainKey) {
                var info = ItemInfo(buffer: currentInfoValue)
                previousContentType = info.contentType
                previousSize = info.size
                info.contentType = contentType
                if let size = size {
                    info.size = size
                }
                // Media is registered on every request; skip the write when nothing changed.
                if info.contentType != previousContentType || info.size != previousSize {
                    self.valueBox.set(self.hashIdToInfoTable, key: mainKey, value: info.serialize())
                }
            } else {
                self.valueBox.set(self.hashIdToInfoTable, key: mainKey, value: ItemInfo(id: id, contentType: contentType, size: size ?? 0).serialize())
            }
            
            let updatedSize = size ?? previousSize
            let deltaSize = updatedSize - previousSize
            
            if let previousContentType = previousContentType {
                if previousContentType != contentType {
                    var referencingPeers = self.peerIdsReferencing(hashId: hashId)
                    
                    if previousSize != 0 {
                        self.internalAddSize(contentType: previousContentType, delta: -previousSize)
                        
                        for peerId in referencingPeers {
                            self.internalAddSize(peerId: peerId, contentType: previousContentType, delta: -previousSize)
                        }
                    }
                    
                    if updatedSize != 0 {
                        self.internalAddSize(contentType: contentType, delta: updatedSize)
                        
                        if !referencingPeers.contains(reference.peerId) {
                            referencingPeers.insert(reference.peerId)
                        }
                        for peerId in referencingPeers {
                            self.internalAddSize(peerId: peerId, contentType: contentType, delta: updatedSize)
                        }
                    }
                } else {
                    let referencingPeers = self.peerIdsReferencing(hashId: hashId)
                    
                    if deltaSize != 0 {
                        self.internalAddSize(contentType: contentType, delta: deltaSize)
                        
                        for peerId in referencingPeers {
                            self.internalAddSize(peerId: peerId, contentType: contentType, delta: deltaSize)
                        }
                    }
                    
                    // A peer referencing this item for the first time is credited with the
                    // whole current size, whether or not the size changed in this call:
                    // `internalRemove` debits every referencing peer by the item's size, so
                    // every referencing peer must have been credited exactly once.
                    if updatedSize != 0 && !referencingPeers.contains(reference.peerId) {
                        self.internalAddSize(peerId: reference.peerId, contentType: contentType, delta: updatedSize)
                    }
                }
            } else if updatedSize != 0 {
                self.internalAddSize(contentType: contentType, delta: updatedSize)
                
                var referencingPeers = self.peerIdsReferencing(hashId: hashId)
                if !referencingPeers.contains(reference.peerId) {
                    referencingPeers.insert(reference.peerId)
                }
                for peerId in referencingPeers {
                    self.internalAddSize(peerId: peerId, contentType: contentType, delta: updatedSize)
                }
            }
            
            let idKey = ValueBoxKey(length: hashId.data.count + 8 + 1 + 4)
            idKey.setData(0, value: hashId.data)
            idKey.setInt64(hashId.data.count, value: reference.peerId)
            idKey.setUInt8(hashId.data.count + 8, value: reference.messageNamespace)
            idKey.setInt32(hashId.data.count + 8 + 1, value: reference.messageId)
            
            var alreadyStored = false
            if !self.valueBox.exists(self.idToReferenceTable, key: idKey) {
                self.valueBox.setOrIgnore(self.idToReferenceTable, key: idKey, value: MemoryBuffer())
            } else {
                alreadyStored = true
            }
            
            if !alreadyStored {
                let peerIdIdKey = ValueBoxKey(length: 8 + 16)
                peerIdIdKey.setInt64(0, value: reference.peerId)
                peerIdIdKey.setData(8, value: hashId.data)
                
                self.valueBox.setOrIgnore(self.peerIdToIdTable, key: peerIdIdKey, value: MemoryBuffer())
            }
        }
        
        func add(reference: Reference, to id: Data, contentType: UInt8, size: Int64?) {
            // Without a size, repeating a stored registration changes nothing.
            if size == nil && self.registrations.contains(id: id, reference: reference, contentType: contentType) {
                return
            }
            self.beginInternalTransaction {
                self.valueBox.begin()
                
                self.internalAdd(reference: reference, to: id, contentType: contentType, size: size)
                
                self.valueBox.commit()
                
                if size == nil {
                    self.registrations.record(id: id, reference: reference, contentType: contentType)
                } else {
                    self.registrations.forget(id: id)
                }
            }
        }
        
        func batchAdd(items: [(reference: Reference, id: Data, contentType: UInt8, size: Int64)]) {
            for item in items {
                self.registrations.forget(id: item.id)
            }
            self.beginInternalTransaction {
                self.valueBox.begin()
                
                for (reference, id, contentType, size) in items {
                    self.registrations.forget(id: id)
                    self.internalAdd(reference: reference, to: id, contentType: contentType, size: size)
                }
                
                self.valueBox.commit()
                
                self.incrementalUpdateTotalSize()
            }
        }
        
        private func peerIdsReferencing(hashId: HashId) -> Set<Int64> {
            let mainKey = ValueBoxKey(length: 16)
            mainKey.setData(0, value: hashId.data)
            
            var peerIds = Set<Int64>()
            self.valueBox.range(self.idToReferenceTable, start: mainKey, end: mainKey.successor, keys: { key in
                let peerId = key.getInt64(16)
                peerIds.insert(peerId)
                return true
            }, limit: 0)
            
            return peerIds
        }
        
        // Size updates arrive for every cached file and downloaded chunk. They are applied in one
        // transaction per batch instead of one each: after `pendingSizeUpdatesDelay`, at
        // `maxPendingSizeUpdates` distinct items, or before any other operation
        // (beginInternalTransaction), so every reader and writer sees them in order. Within a
        // batch only the last size of an item is applied: the result is the same, since an
        // update only sets the size. A crash loses at most one batch of size bookkeeping; the
        // MediaBox scan re-adds files it does not know.
        private static let maxPendingSizeUpdates = 64
        private static let pendingSizeUpdatesDelay = 1.0
        private var pendingSizeUpdates: [(id: Data, size: Int64)] = []
        private var pendingSizeUpdateIndices: [Data: Int] = [:]
        private var isPendingSizeUpdatesFlushScheduled = false
        
        func update(id: Data, size: Int64) {
            assert(self.queue.isCurrent())
            if let index = self.pendingSizeUpdateIndices[id] {
                self.pendingSizeUpdates[index].size = size
                return
            }
            self.pendingSizeUpdateIndices[id] = self.pendingSizeUpdates.count
            self.pendingSizeUpdates.append((id, size))
            if self.pendingSizeUpdates.count >= Impl.maxPendingSizeUpdates {
                self.flushPendingSizeUpdates()
            } else if !self.isPendingSizeUpdatesFlushScheduled {
                self.isPendingSizeUpdatesFlushScheduled = true
                self.queue.after(Impl.pendingSizeUpdatesDelay, { [weak self] in
                    guard let self else {
                        return
                    }
                    self.isPendingSizeUpdatesFlushScheduled = false
                    self.flushPendingSizeUpdates()
                })
            }
        }
        
        func flushPendingSizeUpdates() {
            if self.pendingSizeUpdates.isEmpty {
                return
            }
            let updates = self.pendingSizeUpdates
            self.pendingSizeUpdates.removeAll()
            self.pendingSizeUpdateIndices.removeAll()
            
            self.beginInternalTransaction {
                self.valueBox.begin()
                
                for update in updates {
                    self.internalUpdate(id: update.id, size: update.size)
                }
                
                self.valueBox.commit()
                
                self.incrementalUpdateTotalSize()
            }
        }
        
        private func internalUpdate(id: Data, size: Int64) {
            self.appliedSizeUpdateCount += 1
            let hashId = md5Hash(id)
            
            let mainKey = ValueBoxKey(length: 16)
            mainKey.setData(0, value: hashId.data)
            
            if let currentInfoValue = self.valueBox.get(self.hashIdToInfoTable, key: mainKey) {
                var info = ItemInfo(buffer: currentInfoValue)
                
                var sizeDelta: Int64 = 0
                if info.size != size {
                    sizeDelta = size - info.size
                    info.size = size
                    
                    self.valueBox.set(self.hashIdToInfoTable, key: mainKey, value: info.serialize())
                }
                
                if sizeDelta != 0 {
                    self.internalAddSize(contentType: info.contentType, delta: sizeDelta)
                }
                
                for peerId in self.peerIdsReferencing(hashId: hashId) {
                    self.internalAddSize(peerId: peerId, contentType: info.contentType, delta: sizeDelta)
                }
            } else {
                self.internalAdd(reference: StorageBox.Reference(peerId: 0, messageNamespace: 0, messageId: 0), to: id, contentType: 0, size: size)
            }
        }
        
        func addEmptyReferencesIfNotReferenced(ids: [(id: Data, size: Int64)], contentType: UInt8, completion: @escaping (Int) -> Void) {
            self.beginInternalTransaction {
                self.valueBox.begin()
                
                let mainKey = ValueBoxKey(length: 16)
                var addedCount = 0
                
                for (id, size) in ids {
                    let hashId = md5Hash(id)
                    mainKey.setData(0, value: hashId.data)
                    if self.valueBox.exists(self.hashIdToInfoTable, key: mainKey) {
                        continue
                    }
                    
                    self.registrations.forget(id: id)
                    self.internalAdd(reference: StorageBox.Reference(peerId: 0, messageNamespace: 0, messageId: 0), to: id, contentType: contentType, size: size)
                    addedCount += 1
                }
                
                self.valueBox.commit()
                
                completion(addedCount)
            }
        }
        
        private func internalRemove(hashId: Data) {
            let mainKey = ValueBoxKey(length: 16)
            let peerIdIdKey = ValueBoxKey(length: 8 + 16)
            
            mainKey.setData(0, value: hashId)
            
            guard let infoValue = self.valueBox.get(self.hashIdToInfoTable, key: mainKey) else {
                return
            }
            let info = ItemInfo(buffer: infoValue)
            self.valueBox.remove(self.hashIdToInfoTable, key: mainKey, secure: false)
            
            if info.size != 0 {
                self.internalAddSize(contentType: info.contentType, delta: -info.size)
            }
            
            var referenceKeys: [ValueBoxKey] = []
            self.valueBox.range(self.idToReferenceTable, start: mainKey, end: mainKey.successor, keys: { key in
                referenceKeys.append(key)
                return true
            }, limit: 0)
            var peerIds = Set<Int64>()
            for key in referenceKeys {
                peerIds.insert(key.getInt64(16))
                self.valueBox.remove(self.idToReferenceTable, key: key, secure: false)
            }
            
            for peerId in peerIds {
                peerIdIdKey.setInt64(0, value: peerId)
                peerIdIdKey.setData(8, value: hashId)
                
                if self.valueBox.exists(self.peerIdToIdTable, key: peerIdIdKey) {
                    self.valueBox.remove(self.peerIdToIdTable, key: peerIdIdKey, secure: false)
                    
                    if info.size != 0 {
                        self.internalAddSize(peerId: peerId, contentType: info.contentType, delta: -info.size)
                    }
                }
            }
        }
        
        func remove(ids: [Data]) {
            for id in ids {
                self.registrations.forget(id: id)
            }
            self.beginInternalTransaction {
                self.valueBox.begin()
                
                for id in ids {
                    self.registrations.forget(id: id)
                    self.internalRemove(hashId: md5Hash(id).data)
                }
                
                self.valueBox.commit()
                
                self.incrementalUpdateTotalSize()
            }
        }
        
        func allPeerIds(completion: @escaping([PeerId]) -> Void) {
            self.beginInternalTransaction {
                var result: [PeerId] = []
                
                self.valueBox.begin()
                
                var fromKey = ValueBoxKey(length: 8)
                fromKey.setInt64(0, value: 0)
                
                let toKey = ValueBoxKey(length: 8)
                toKey.setInt64(0, value: Int64.max)
                
                while true {
                    var peerId: Int64?
                    self.valueBox.range(self.peerIdToIdTable, start: fromKey, end: toKey, keys: { key in
                        peerId = key.getInt64(0)
                        return false
                    }, limit: 1)
                    
                    if let peerId = peerId {
                        if peerId != 0 {
                            result.append(PeerId(peerId))
                        }
                        
                        fromKey.setInt64(0, value: peerId)
                        fromKey = fromKey.successor
                    } else {
                        break
                    }
                }
                
                self.valueBox.commit()
                
                completion(result)
            }
        }
        
        private func allInternal(peerId: PeerId, excludeType: UInt8) -> [Data] {
            var hashIds: [Data] = []
            let peerIdIdKey = ValueBoxKey(length: 8)
            peerIdIdKey.setInt64(0, value: peerId.toInt64())
            self.valueBox.range(self.peerIdToIdTable, start: peerIdIdKey, end: peerIdIdKey.successor, keys: { key in
                hashIds.append(key.getData(8, length: 16))
                return true
            }, limit: 0)
            
            var result: [Data] = []
            let mainKey = ValueBoxKey(length: 16)
            for hashId in hashIds {
                mainKey.setData(0, value: hashId)
                if let infoValue = self.valueBox.get(self.hashIdToInfoTable, key: mainKey) {
                    let info = ItemInfo(buffer: infoValue)
                    if info.contentType != excludeType {
                        result.append(info.id)
                    }
                }
            }
            
            return result
        }
        
        private func allInternal(peerId: PeerId, onlyType: UInt8) -> [Data] {
            var hashIds: [Data] = []
            let peerIdIdKey = ValueBoxKey(length: 8)
            peerIdIdKey.setInt64(0, value: peerId.toInt64())
            self.valueBox.range(self.peerIdToIdTable, start: peerIdIdKey, end: peerIdIdKey.successor, keys: { key in
                hashIds.append(key.getData(8, length: 16))
                return true
            }, limit: 0)
            
            var result: [Data] = []
            let mainKey = ValueBoxKey(length: 16)
            for hashId in hashIds {
                mainKey.setData(0, value: hashId)
                if let infoValue = self.valueBox.get(self.hashIdToInfoTable, key: mainKey) {
                    let info = ItemInfo(buffer: infoValue)
                    if info.contentType == onlyType {
                        result.append(info.id)
                    }
                }
            }
            
            return result
        }
        
        func all(peerId: PeerId, excludeType: UInt8, completion: @escaping ([Data]) -> Void) {
            self.beginInternalTransaction {
                self.valueBox.begin()
                
                let result = self.allInternal(peerId: peerId, excludeType: excludeType)
                
                self.valueBox.commit()
                
                completion(result)
            }
        }
        
        func all(peerId: PeerId, onlyType: UInt8, completion: @escaping ([Data]) -> Void) {
            self.beginInternalTransaction {
                self.valueBox.begin()
                
                let result = self.allInternal(peerId: peerId, onlyType: onlyType)
                
                self.valueBox.commit()
                
                completion(result)
            }
        }
        
        func enumerateItems(startingWith startId: Data?, limit: Int, completion: @escaping ((ids: [Data], nextStartId: Data?)) -> Void) {
            self.beginInternalTransaction {
                self.valueBox.begin()
                
                let startKey: ValueBoxKey
                if let startId = startId, startId.count == 16 {
                    startKey = ValueBoxKey(length: 16)
                    startKey.setData(0, value: startId)
                } else {
                    startKey = ValueBoxKey(length: 1)
                    startKey.setUInt8(0, value: 0)
                }
                
                let endKey = ValueBoxKey(length: 16)
                for i in 0 ..< 16 {
                    endKey.setUInt8(i, value: 0xff)
                }
                
                var ids: [Data] = []
                var nextKey: ValueBoxKey?
                self.valueBox.range(self.hashIdToInfoTable, start: startKey, end: endKey, values: { key, value in
                    nextKey = key
                    
                    let info = ItemInfo(buffer: value)
                    ids.append(info.id)
                    
                    return true
                }, limit: limit)
                
                self.valueBox.commit()
                
                var nextId = nextKey?.getData(0, length: 16)
                if nextId == startId {
                    nextId = nil
                }
                
                completion((ids, nextId))
            }
        }
        
        func subscribeTotalSize(next: @escaping (Int64) -> Void) -> Disposable {
            self.flushPendingSizeUpdates()
            let index = self.totalSizeSubscribers.add(next)
            
            next(self.totalSize)
            
            let queue = self.queue
            return ActionDisposable { [weak self] in
                queue.async {
                    guard let `self` = self else {
                        return
                    }
                    self.totalSizeSubscribers.remove(index)
                }
            }
        }
        
        func all(completion: @escaping ([Entry]) -> Void) {
            self.beginInternalTransaction {
                var result: [Entry] = []
                
                self.valueBox.begin()
                
                var currentId: Data?
                var currentReferences: [Reference] = []
                
                let mainKey = ValueBoxKey(length: 16)
                
                self.valueBox.scan(self.idToReferenceTable, keys: { key in
                    let id = key.getData(0, length: 16)
                    
                    let peerId = key.getInt64(16)
                    let messageNamespace: UInt8 = key.getUInt8(16 + 8)
                    let messageId = key.getInt32(16 + 8 + 1)
                    
                    let reference = Reference(peerId: peerId, messageNamespace: messageNamespace, messageId: messageId)
                    
                    if currentId == id {
                        currentReferences.append(reference)
                    } else {
                        if let currentId = currentId, !currentReferences.isEmpty {
                            mainKey.setData(0, value: currentId)
                            if let infoValue = self.valueBox.get(self.hashIdToInfoTable, key: mainKey) {
                                let info = ItemInfo(buffer: infoValue)
                                result.append(StorageBox.Entry(id: info.id, references: currentReferences))
                            }
                            currentReferences.removeAll(keepingCapacity: true)
                        }
                        currentId = id
                        currentReferences.append(reference)
                    }
                    
                    return true
                })
                
                self.valueBox.commit()
                
                completion(result)
            }
        }
        
        func get(ids: [Data], completion: @escaping ([Entry]) -> Void) {
            self.beginInternalTransaction {
                var result: [Entry] = []
                
                self.valueBox.begin()
                
                let idKey = ValueBoxKey(length: 16)
                
                for id in ids {
                    let hashId = md5Hash(id)
                    idKey.setData(0, value: hashId.data)
                    var currentReferences: [Reference] = []
                    self.valueBox.range(self.idToReferenceTable, start: idKey, end: idKey.successor, keys: { key in
                        let peerId = key.getInt64(16)
                        let messageNamespace: UInt8 = key.getUInt8(16 + 8)
                        let messageId = key.getInt32(16 + 8 + 1)
                        
                        let reference = Reference(peerId: peerId, messageNamespace: messageNamespace, messageId: messageId)
                        
                        currentReferences.append(reference)
                        return true
                    }, limit: 0)
                    
                    if !currentReferences.isEmpty {
                        result.append(StorageBox.Entry(id: id, references: currentReferences))
                    }
                }
                
                self.valueBox.commit()
                
                completion(result)
            }
        }
        
        func getAllStats(completion: @escaping (AllStats) -> Void) {
            self.beginInternalTransaction {
                self.valueBox.begin()
                
                let allStats = AllStats(total: StorageBox.Stats(contentTypes: [:]), peers: [:])
                
                self.valueBox.scan(self.contentTypeStatsTable, values: { key, value in
                    var size: Int64 = 0
                    value.read(&size, offset: 0, length: 8)
                    allStats.total.contentTypes[key.getUInt8(0)] = Stats.ContentTypeStats(size: size, messages: [:])
                    
                    return true
                })
                
                self.valueBox.scan(self.peerContentTypeStatsTable, values: { key, value in
                    var size: Int64 = 0
                    value.read(&size, offset: 0, length: 8)
                    
                    let peerId = key.getInt64(0)
                    let contentType = key.getUInt8(8)
                    if allStats.peers[PeerId(peerId)] == nil {
                        allStats.peers[PeerId(peerId)] = StorageBox.Stats(contentTypes: [:])
                    }
                    allStats.peers[PeerId(peerId)]?.contentTypes[contentType] = Stats.ContentTypeStats(size: size, messages: [:])
                    
                    return true
                })
                
                let idKey = ValueBoxKey(length: 16 + 8)
                
                let mainKey = ValueBoxKey(length: 16)
                var processedIds = Set<Data>()
                self.valueBox.scan(self.peerIdToIdTable, keys: { key in
                    let peerId = key.getInt64(0)
                    if peerId == 0 {
                        return true
                    }
                    
                    let hashId = key.getData(8, length: 16)
                    if processedIds.contains(hashId) {
                        return true
                    }
                    processedIds.insert(hashId)
                    
                    mainKey.setData(0, value: hashId)
                    if let currentInfoValue = self.valueBox.get(self.hashIdToInfoTable, key: mainKey) {
                        let info = ItemInfo(buffer: currentInfoValue)
                        if info.size != 0 {
                            idKey.setData(0, value: hashId)
                            idKey.setInt64(16, value: peerId)
                            
                            let contentType = info.contentType
                            if contentType == 0 {
                                return true
                            }
                            
                            self.valueBox.range(self.idToReferenceTable, start: idKey, end: idKey.successor, keys: { subKey in
                                let messageNamespace: UInt8 = subKey.getUInt8(16 + 8)
                                let messageId = subKey.getInt32(16 + 8 + 1)
                                
                                if messageId != 0 {
                                    allStats.total.contentTypes[contentType]?.messages[MessageId(peerId: PeerId(peerId), namespace: Int32(messageNamespace), id: messageId), default: 0] += info.size
                                    allStats.peers[PeerId(peerId)]?.contentTypes[contentType]?.messages[MessageId(peerId: PeerId(peerId), namespace: Int32(messageNamespace), id: messageId), default: 0] += info.size
                                }
                                
                                return true
                            }, limit: 1)
                        }
                    }
                    
                    return true
                })
                
                self.valueBox.commit()
                
                completion(allStats)
            }
        }
        
        func remove(peerId: Int64?, contentTypes: [UInt8], includeIds: [Data], excludeIds: [Data], completion: @escaping ([Data]) -> Void) {
            // The removed ids are known only once it runs.
            self.registrations.forgetAll()
            self.beginInternalTransaction {
                self.registrations.forgetAll()
                var resultIds: [Data] = []
                
                self.valueBox.begin()
                
                var scannedIds: [Data: Data] = [:]
                
                self.valueBox.scan(self.hashIdToInfoTable, values: { key, value in
                    let info = ItemInfo(buffer: value)
                    if !contentTypes.contains(info.contentType) {
                        return true
                    }
                    scannedIds[key.getData(0, length: 16)] = info.id
                    return true
                })
                
                for id in includeIds {
                    scannedIds[md5Hash(id).data] = id
                }
                
                let excludeIds = Set(excludeIds)
                
                if let peerId = peerId {
                    var filteredHashIds: [Data] = []
                    self.valueBox.scan(self.idToReferenceTable, keys: { key in
                        let id = key.getData(0, length: 16)
                        guard let realId = scannedIds[id] else {
                            return true
                        }
                        if excludeIds.contains(realId) {
                            return true
                        }
                        
                        let itemPeerId = key.getInt64(16)
                        
                        if itemPeerId == peerId {
                            filteredHashIds.append(id)
                        }
                        
                        return true
                    })
                    for hashId in filteredHashIds {
                        if let id = scannedIds[hashId] {
                            self.internalRemove(hashId: hashId)
                            resultIds.append(id)
                        }
                    }
                } else {
                    for (hashId, id) in scannedIds {
                        if excludeIds.contains(id) {
                            continue
                        }
                        self.internalRemove(hashId: hashId)
                        resultIds.append(id)
                    }
                }
                
                self.valueBox.commit()
                
                self.incrementalUpdateTotalSize()
                
                completion(Array(resultIds))
            }
        }
        
        func remove(peerIds: Set<PeerId>, includeIds: [Data], excludeIds: [Data], completion: @escaping ([Data]) -> Void) {
            self.registrations.forgetAll()
            self.beginInternalTransaction {
                self.registrations.forgetAll()
                var resultIds: [Data] = []
                
                self.valueBox.begin()
                
                var scannedIds = Set<Data>()
                for peerId in peerIds {
                    scannedIds.formUnion(self.allInternal(peerId: peerId, excludeType: UInt8.max))
                }
                
                for id in includeIds {
                    scannedIds.insert(id)
                }
                
                let excludedIds = Set(excludeIds)
                
                for id in scannedIds {
                    if excludedIds.contains(id) {
                        continue
                    }
                    self.internalRemove(hashId: md5Hash(id).data)
                    resultIds.append(id)
                }
                
                self.valueBox.commit()
                
                self.incrementalUpdateTotalSize()
                
                completion(Array(resultIds))
            }
        }
        
        private func beginInternalTransaction(ignoreDisabled: Bool = false, _ f: @escaping () -> Void) {
            assert(self.queue.isCurrent())
            // Pending size updates go first, so `f` sees them.
            self.flushPendingSizeUpdates()
            if ignoreDisabled || self.canBeginTransactionsValue.with({ $0 }) {
                self.transactionCount += 1
                f()
            } else {
                let _ = self.queuedInternalTransactions.modify { fs in
                    var fs = fs
                    fs.append(f)
                    return fs
                }
            }
        }
        
        let canBeginTransactionsValue = Atomic<Bool>(value: true)
        func setCanBeginTransactions(_ value: Bool, afterTransactionIfRunning: @escaping () -> Void) {
            if !value {
                // Write what is pending while writes are still allowed (the app is about to suspend).
                self.flushPendingSizeUpdates()
            }
            let previous = self.canBeginTransactionsValue.swap(value)
            if previous != value && value {
                let fs = self.queuedInternalTransactions.swap([])
                for f in fs {
                    self.transactionCount += 1
                    f()
                }
            }
            afterTransactionIfRunning()
        }
    }
    
    static let defaultRegistrationCacheCapacity = 1024
    static var registrationCacheCapacity = StorageBox.defaultRegistrationCacheCapacity
    
    /// What the box has done so far (for tests).
    struct DebugState {
        var isOpen = false
        var transactions = 0
        var appliedSizeUpdates = 0
        var registrationCacheCount = 0
    }
    
    /// Does not open the database.
    func debugState() -> Signal<DebugState, NoError> {
        return self.impl.holder.signalWith { holder, subscriber in
            var state = DebugState()
            if let impl = holder.openedImpl {
                state = DebugState(isOpen: true, transactions: impl.transactionCount, appliedSizeUpdates: impl.appliedSizeUpdateCount, registrationCacheCount: impl.registrationCacheCount)
            }
            subscriber.putNext(state)
            subscriber.putCompletion()
            return EmptyDisposable
        }
    }
    
    /// Opens the database on first use. The app opens it right away; app extensions (the
    /// notification service, widget, intents) often only build paths and never need it, and
    /// opening costs a file open and three write transactions. While transactions are disabled
    /// (suspension) it is not opened at all; work asked for meanwhile runs, in order, once they
    /// are enabled again.
    private final class ImplHolder {
        private let open: () -> Impl
        private(set) var openedImpl: Impl?
        private var canBeginTransactions = true
        private var waiting: [(Impl) -> Void] = []
        
        init(open: @escaping () -> Impl, openNow: Bool) {
            self.open = open
            if openNow {
                self.openedImpl = open()
            }
        }
        
        func with(_ f: @escaping (Impl) -> Void) {
            if let impl = self.openedImpl {
                f(impl)
            } else if !self.canBeginTransactions {
                self.waiting.append(f)
            } else {
                let impl = self.open()
                self.openedImpl = impl
                f(impl)
            }
        }
        
        func setCanBeginTransactions(_ value: Bool, afterTransactionIfRunning: @escaping () -> Void) {
            if let impl = self.openedImpl {
                impl.setCanBeginTransactions(value, afterTransactionIfRunning: afterTransactionIfRunning)
                return
            }
            self.canBeginTransactions = value
            if value && !self.waiting.isEmpty {
                let waiting = self.waiting
                self.waiting = []
                let impl = self.open()
                self.openedImpl = impl
                for f in waiting {
                    f(impl)
                }
            }
            afterTransactionIfRunning()
        }
    }
    
    /// `QueueLocalObject`-like access that goes through `ImplHolder`.
    private struct LazyImpl {
        let holder: QueueLocalObject<ImplHolder>
        
        func with(_ f: @escaping (Impl) -> Void) {
            self.holder.with { holder in
                holder.with(f)
            }
        }
        
        func signalWith<R, E>(_ f: @escaping (Impl, Subscriber<R, E>) -> Disposable) -> Signal<R, E> {
            return self.holder.signalWith { holder, subscriber in
                let disposable = MetaDisposable()
                holder.with { impl in
                    disposable.set(f(impl, subscriber))
                }
                return disposable
            }
        }
    }
    
    private static let sharedQueue = Queue(name: "StorageBox-Shared")
    private let queue: Queue
    private let impl: LazyImpl
    
    public init(logger: StorageBox.Logger, basePath: String, isMainProcess: Bool) {
        let queue = StorageBox.sharedQueue
        self.queue = queue
        self.impl = LazyImpl(holder: QueueLocalObject(queue: queue, generate: {
            return ImplHolder(open: {
                return Impl(queue: queue, logger: logger, basePath: basePath, isMainProcess: isMainProcess)
            }, openNow: isMainProcess)
        }))
    }
    
    public func add(reference: Reference, to id: Data, contentType: UInt8) {
        self.impl.with { impl in
            impl.add(reference: reference, to: id, contentType: contentType, size: nil)
        }
    }
    
    public func update(id: Data, size: Int64) {
        self.impl.with { impl in
            impl.update(id: id, size: size)
        }
    }
    
    public func addEmptyReferencesIfNotReferenced(ids: [(id: Data, size: Int64)], contentType: UInt8, completion: @escaping (Int) -> Void) {
        self.impl.with { impl in
            impl.addEmptyReferencesIfNotReferenced(ids: ids, contentType: contentType, completion: completion)
        }
    }
    
    public func batchAdd(items: [(reference: Reference, id: Data, contentType: UInt8, size: Int64)]) {
        self.impl.with { impl in
            impl.batchAdd(items: items)
        }
    }
    
    public func remove(ids: [Data]) {
        self.impl.with { impl in
            impl.remove(ids: ids)
        }
    }
    
    public func all() -> Signal<[Entry], NoError> {
        return self.impl.signalWith { impl, subscriber in
            impl.all(completion: { result in
                subscriber.putNext(result)
                subscriber.putCompletion()
            })
            
            return EmptyDisposable
        }
    }
    
    public func allPeerIds() -> Signal<[PeerId], NoError> {
        return self.impl.signalWith { impl, subscriber in
            impl.allPeerIds(completion: { result in
                subscriber.putNext(result)
                subscriber.putCompletion()
            })
            
            return EmptyDisposable
        }
    }
    
    public func all(peerId: PeerId, excludeType: UInt8) -> Signal<[Data], NoError> {
        return self.impl.signalWith { impl, subscriber in
            impl.all(peerId: peerId, excludeType: excludeType, completion: { result in
                subscriber.putNext(result)
                subscriber.putCompletion()
            })
            
            return EmptyDisposable
        }
    }
    
    public func all(peerId: PeerId, onlyType: UInt8) -> Signal<[Data], NoError> {
        return self.impl.signalWith { impl, subscriber in
            impl.all(peerId: peerId, onlyType: onlyType, completion: { result in
                subscriber.putNext(result)
                subscriber.putCompletion()
            })
            
            return EmptyDisposable
        }
    }
    
    public func get(ids: [Data]) -> Signal<[Entry], NoError> {
        return self.impl.signalWith { impl, subscriber in
            impl.get(ids: ids, completion: { result in
                subscriber.putNext(result)
                subscriber.putCompletion()
            })
            
            return EmptyDisposable
        }
    }
    
    public func getAllStats() -> Signal<AllStats, NoError> {
        return self.impl.signalWith { impl, subscriber in
            impl.getAllStats(completion: { result in
                subscriber.putNext(result)
                subscriber.putCompletion()
            })
            
            return EmptyDisposable
        }
    }
    
    public func remove(peerId: PeerId?, contentTypes: [UInt8], includeIds: [Data], excludeIds: [Data], completion: @escaping ([Data]) -> Void) {
        self.impl.with { impl in
            impl.remove(peerId: peerId?.toInt64(), contentTypes: contentTypes, includeIds: includeIds, excludeIds: excludeIds, completion: { result in
                completion(result)
            })
        }
    }
    
    public func remove(peerIds: Set<PeerId>, includeIds: [Data], excludeIds: [Data], completion: @escaping ([Data]) -> Void) {
        self.impl.with { impl in
            impl.remove(peerIds: peerIds, includeIds: includeIds, excludeIds: excludeIds, completion: { result in
                completion(result)
            })
        }
    }
    
    /// Frees SQLite page-cache memory (background, memory warning).
    public func releaseMemory() {
        self.impl.holder.with { holder in
            guard let impl = holder.openedImpl else {
                return
            }
            impl.flushPendingSizeUpdates()
            impl.valueBox.releaseMemory()
        }
    }

    func pageCacheMemoryUsed() -> Int {
        return self.impl.holder.syncWith { holder in
            return holder.openedImpl?.valueBox.pageCacheMemoryUsed() ?? 0
        }
    }

    public func reset() {
        self.impl.with { impl in
            impl.reset()
        }
    }
    
    public func enumerateItems(startingWith startId: Data?, limit: Int) -> Signal<(ids: [Data], nextStartId: Data?), NoError> {
        return self.impl.signalWith { impl, subscriber in
            impl.enumerateItems(startingWith: startId, limit: limit, completion: { result in
                subscriber.putNext(result)
                subscriber.putCompletion()
            })
            
            return EmptyDisposable
        }
    }
    
    public func totalSize() -> Signal<Int64, NoError> {
        return self.impl.signalWith { impl, subscriber in
            return impl.subscribeTotalSize(next: { value in
                subscriber.putNext(value)
            })
        }
    }
    
    public func setCanBeginTransactions(_ value: Bool, afterTransactionIfRunning: @escaping () -> Void) {
        self.impl.holder.with { holder in
            holder.setCanBeginTransactions(value, afterTransactionIfRunning: afterTransactionIfRunning)
        }
    }
}
