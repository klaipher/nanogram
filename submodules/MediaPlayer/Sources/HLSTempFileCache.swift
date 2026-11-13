import Foundation
import Postbox
import DiskWriteAccounting

/// The temporary files of hardware AV1 HLS parts, which AVFoundation can only read from a path.
///
/// A part made again for the same bytes (a looping muted video, a seek back, a re-buffer after the player dropped
/// its parts) reuses the file written the first time instead of writing the segment once more. Files are keyed by
/// resource, initialization range and data range. A file in use by a part is never evicted; the files nobody uses are
/// kept up to `maxEntries` and `maxBytes` (least recently used first) and disposed when pushed out.
public final class HLSTempFileCache: @unchecked Sendable {
    public static let shared = HLSTempFileCache()

    public struct Key: Hashable, Sendable {
        public let resourceId: String
        public let initRange: Range<Int64>?
        public let dataRange: Range<Int64>

        public init(resourceId: String, initRange: Range<Int64>?, dataRange: Range<Int64>) {
            self.resourceId = resourceId
            self.initRange = initRange
            self.dataRange = dataRange
        }
    }

    private final class Entry {
        let key: Key
        let file: TempBoxFile
        let bytes: Int
        var users: Int = 0
        var lastUse: Int = 0

        init(key: Key, file: TempBoxFile, bytes: Int) {
            self.key = key
            self.file = file
            self.bytes = bytes
        }
    }

    private let maxEntries: Int
    private let maxBytes: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var pathToKey: [String: Key] = [:]
    private var useCounter: Int = 0

    public init(maxEntries: Int = 16, maxBytes: Int = 64 * 1024 * 1024) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    /// The number of files held, in use or not.
    public var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.entries.count
    }

    /// The file for `key`: the cached one, or the one `write` makes (it returns the file and the bytes it wrote).
    /// The caller holds the file until it calls `release`.
    public func acquire(key: Key, write: () -> (file: TempBoxFile, bytes: Int)?) -> TempBoxFile? {
        var staleFile: TempBoxFile?
        self.lock.lock()
        if let entry = self.entries[key] {
            if FileManager.default.fileExists(atPath: entry.file.path) {
                entry.users += 1
                self.useCounter += 1
                entry.lastUse = self.useCounter
                self.lock.unlock()
                return entry.file
            }
            self.remove(entry: entry)
            staleFile = entry.file
        }
        self.lock.unlock()
        if let staleFile {
            TempBox.shared.dispose(staleFile)
        }

        guard let written = write() else {
            return nil
        }

        self.lock.lock()
        if let existing = self.entries[key] {
            existing.users += 1
            self.useCounter += 1
            existing.lastUse = self.useCounter
            self.lock.unlock()
            TempBox.shared.dispose(written.file)
            return existing.file
        }
        let entry = Entry(key: key, file: written.file, bytes: written.bytes)
        entry.users = 1
        self.useCounter += 1
        entry.lastUse = self.useCounter
        self.entries[key] = entry
        self.pathToKey[written.file.path] = key
        let evicted = self.evictedEntries()
        self.lock.unlock()

        for file in evicted {
            TempBox.shared.dispose(file)
        }
        return written.file
    }

    /// Gives a file back. Returns false when the cache does not own `file`; the caller disposes it then.
    public func release(_ file: TempBoxFile) -> Bool {
        self.lock.lock()
        guard let key = self.pathToKey[file.path], let entry = self.entries[key] else {
            self.lock.unlock()
            return false
        }
        if entry.users > 0 {
            entry.users -= 1
        }
        let evicted = self.evictedEntries()
        self.lock.unlock()

        for file in evicted {
            TempBox.shared.dispose(file)
        }
        return true
    }

    /// Disposes every file nobody uses.
    public func trimUnused() {
        self.lock.lock()
        var files: [TempBoxFile] = []
        for entry in Array(self.entries.values) where entry.users == 0 {
            self.remove(entry: entry)
            files.append(entry.file)
        }
        self.lock.unlock()

        for file in files {
            TempBox.shared.dispose(file)
        }
    }

    private func remove(entry: Entry) {
        self.entries.removeValue(forKey: entry.key)
        if self.pathToKey[entry.file.path] == entry.key {
            self.pathToKey.removeValue(forKey: entry.file.path)
        }
    }

    private func evictedEntries() -> [TempBoxFile] {
        var result: [TempBoxFile] = []
        var totalBytes = self.entries.values.reduce(0, { $0 + $1.bytes })
        let unused = self.entries.values.filter({ $0.users == 0 }).sorted(by: { $0.lastUse < $1.lastUse })
        var remaining = self.entries.count
        for entry in unused {
            if remaining <= self.maxEntries && totalBytes <= self.maxBytes {
                break
            }
            self.remove(entry: entry)
            result.append(entry.file)
            remaining -= 1
            totalBytes -= entry.bytes
        }
        return result
    }
}
