import Darwin

/// The process's memory as the system accounts it (`task_vm_info`), in bytes. `footprint` is what iOS limits and
/// what Xcode's gauge, MetricKit's memory at suspension and jetsam use; the ledger tags split off what IOSurfaces and
/// Metal (graphics) and media buffers hold, and `mallocInUse` is the malloc heap.
public struct ProcessMemory: Sendable, Equatable {
    public var footprint: UInt64
    public var footprintPeak: UInt64
    public var internalBytes: UInt64
    public var compressed: UInt64
    public var purgeableVolatile: UInt64
    public var graphics: UInt64
    public var media: UInt64
    public var mallocInUse: UInt64

    public init(footprint: UInt64, footprintPeak: UInt64, internalBytes: UInt64, compressed: UInt64, purgeableVolatile: UInt64, graphics: UInt64, media: UInt64, mallocInUse: UInt64) {
        self.footprint = footprint
        self.footprintPeak = footprintPeak
        self.internalBytes = internalBytes
        self.compressed = compressed
        self.purgeableVolatile = purgeableVolatile
        self.graphics = graphics
        self.media = media
        self.mallocInUse = mallocInUse
    }

    /// Reads the current values, nil if the kernel refuses.
    public static func current() -> ProcessMemory? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            unsafe pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integers in
                unsafe task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), integers, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        var zone = malloc_statistics_t()
        unsafe malloc_zone_statistics(nil, &zone)
        func nonNegative(_ value: Int64) -> UInt64 {
            return UInt64(clamping: value)
        }
        return ProcessMemory(
            footprint: info.phys_footprint,
            footprintPeak: nonNegative(info.ledger_phys_footprint_peak),
            internalBytes: info.internal,
            compressed: info.compressed,
            purgeableVolatile: info.purgeable_volatile_pmap,
            graphics: nonNegative(info.ledger_tag_graphics_footprint),
            media: nonNegative(info.ledger_tag_media_footprint),
            mallocInUse: UInt64(clamping: zone.size_in_use)
        )
    }
}
