import Darwin
import Foundation

/// Heap in use per malloc zone. The default zone holds Swift and Objective-C objects and buffers; other zones belong to
/// system frameworks (image decoding, Core Graphics), which shows whether growth is the app's own objects.
public struct MallocZoneUsage: Sendable, Equatable {
    public var name: String
    public var bytes: UInt64
    public var blocks: Int

    public init(name: String, bytes: UInt64, blocks: Int) {
        self.name = name
        self.bytes = bytes
        self.blocks = blocks
    }

    /// The `limit` largest zones. The statistics are counters kept by the zones, so this is cheap, but a zone may take its
    /// lock, so call it off the main thread when the app is busy.
    public static func largest(limit: Int) -> [MallocZoneUsage] {
        var addresses: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        guard unsafe malloc_get_all_zones(mach_task_self_, nil, &addresses, &count) == KERN_SUCCESS, let addresses = unsafe addresses else {
            return []
        }
        var result: [MallocZoneUsage] = []
        for index in 0 ..< Int(count) {
            guard let zone = unsafe UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(unsafe addresses[index])) else {
                continue
            }
            var statistics = malloc_statistics_t()
            unsafe malloc_zone_statistics(zone, &statistics)
            let name = unsafe malloc_get_zone_name(zone).map { unsafe String(cString: $0) } ?? "zone\(index)"
            result.append(MallocZoneUsage(name: name, bytes: UInt64(clamping: statistics.size_in_use), blocks: Int(statistics.blocks_in_use)))
        }
        result.sort { $0.bytes > $1.bytes }
        return Array(result.prefix(max(0, limit)))
    }
}

public enum MemoryRelief {
    /// Asks malloc to return free pages it still holds to the system (what the system does itself on a memory warning).
    /// Does not touch memory that is in use. Cheap when there is little to give back; call it off the main thread.
    public static func returnFreeHeapPages() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    /// Live thread count (a stuck pool of threads holds stacks and their allocations).
    public static func threadCount() -> Int? {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard unsafe task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads = unsafe threads else {
            return nil
        }
        for index in 0 ..< Int(count) {
            _ = unsafe mach_port_deallocate(mach_task_self_, unsafe threads[index])
        }
        _ = unsafe vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
        return Int(count)
    }
}

enum MemoryFormat {
    static func megabytes(_ bytes: UInt64) -> String {
        let tenths = (bytes * 10 + 512 * 1024) / (1024 * 1024)
        return "\(tenths / 10).\(tenths % 10) MB"
    }

    static func size(_ entry: MemoryProbeRegistry.Entry) -> String {
        var text = "\(entry.name) \(entry.count)"
        if let bytes = entry.bytes {
            text += "/" + megabytes(bytes)
        }
        if entry.instances > 1 {
            text += " in \(entry.instances)"
        }
        return text
    }

    static func summary(_ memory: ProcessMemory) -> String {
        return "footprint \(megabytes(memory.footprint)) (internal \(megabytes(memory.internalBytes)), compressed \(megabytes(memory.compressed)), graphics \(megabytes(memory.graphics)), media \(megabytes(memory.media)), malloc \(megabytes(memory.mallocInUse)))"
    }
}

/// The periodic "who holds memory" line: the process numbers, the heap by zone, the live-object counts and the sizes the
/// app's caches report.
public struct MemoryDetailReport: Sendable, Equatable {
    public var memory: ProcessMemory?
    public var threads: Int?
    public var zones: [MallocZoneUsage]
    public var caches: [MemoryProbeRegistry.Entry]
    public var instances: [MemoryProbeRegistry.Entry]
    /// What the app may still allocate before the system ends it (`ProcessMemory.availableHeadroom()`), when known.
    public var headroom: UInt64?

    public init(memory: ProcessMemory?, threads: Int?, zones: [MallocZoneUsage], caches: [MemoryProbeRegistry.Entry], instances: [MemoryProbeRegistry.Entry], headroom: UInt64? = nil) {
        self.headroom = headroom
        self.memory = memory
        self.threads = threads
        self.zones = zones
        self.caches = caches
        self.instances = instances
    }

    public var logLine: String {
        var parts: [String] = []
        if let memory = self.memory {
            parts.append(MemoryFormat.summary(memory))
        } else {
            parts.append("footprint unavailable")
        }
        if let headroom = self.headroom {
            parts.append("headroom \(MemoryFormat.megabytes(headroom))")
        }
        if let threads = self.threads {
            parts.append("threads \(threads)")
        }
        if !self.zones.isEmpty {
            parts.append("heap by zone [" + self.zones.map { "\($0.name) \(MemoryFormat.megabytes($0.bytes)) in \($0.blocks) blocks" }.joined(separator: ", ") + "]")
        }
        parts.append("live objects [" + self.instances.map { "\($0.name) \($0.count)" }.joined(separator: ", ") + "]")
        parts.append("caches [" + self.caches.map(MemoryFormat.size).joined(separator: ", ") + "]")
        return "Memory detail: " + parts.joined(separator: "; ")
    }
}

/// One purge (entering the background, a memory warning): the footprint before and after, and what was asked to give
/// memory back.
public struct MemoryPurgeReport: Sendable, Equatable {
    public var reason: String
    public var before: ProcessMemory?
    public var after: ProcessMemory?
    public var purged: [String]

    public init(reason: String, before: ProcessMemory?, after: ProcessMemory?, purged: [String]) {
        self.reason = reason
        self.before = before
        self.after = after
        self.purged = purged
    }

    public var logLine: String {
        var parts: [String] = []
        if let before = self.before {
            parts.append("before " + MemoryFormat.summary(before))
        } else {
            parts.append("before unavailable")
        }
        if let after = self.after {
            parts.append("after " + MemoryFormat.summary(after))
        } else {
            parts.append("after not measured")
        }
        parts.append("purged [" + self.purged.joined(separator: ", ") + "]")
        return "Memory purge (\(self.reason)): " + parts.joined(separator: "; ")
    }
}
