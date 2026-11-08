import XCTest
@testable import BackgroundDiagnostics

private final class Counter: @unchecked Sendable {
    var value = 0
}

final class MemoryProbeRegistryTests: XCTestCase {
    func testSnapshotAddsUpProbesWithTheSameName() {
        let registry = MemoryProbeRegistry()
        let first = registry.register(name: "pool", read: { .init(count: 2, bytes: 100) })
        let second = registry.register(name: "pool", read: { .init(count: 3, bytes: nil) })
        let other = registry.register(name: "a", read: { .init(count: 1) })
        let snapshot = registry.snapshot()
        XCTAssertEqual(snapshot.caches, [
            .init(name: "a", instances: 1, count: 1, bytes: nil),
            .init(name: "pool", instances: 2, count: 5, bytes: 100)
        ])
        withExtendedLifetime((first, second, other)) {}
    }

    func testReleasingRegistrationRemovesProbeAndPurge() {
        let registry = MemoryProbeRegistry()
        let purged = Counter()
        var probe: MemoryProbeRegistry.Registration? = registry.register(name: "x", read: { .init(count: 1) })
        var purge: MemoryProbeRegistry.Registration? = registry.registerPurge(name: "x", run: { purged.value += 1 })
        XCTAssertEqual(registry.snapshot().caches.count, 1)
        XCTAssertEqual(registry.purgeAll(), ["x"])
        XCTAssertEqual(purged.value, 1)
        probe = nil
        purge = nil
        XCTAssertEqual(registry.snapshot().caches, [])
        XCTAssertEqual(registry.purgeAll(), [])
        XCTAssertEqual(purged.value, 1)
        _ = (probe, purge)
    }

    func testPurgeAllListsRepeatedNamesOnce() {
        let registry = MemoryProbeRegistry()
        let a = registry.registerPurge(name: "rows", run: {})
        let b = registry.registerPurge(name: "rows", run: {})
        let c = registry.registerPurge(name: "avatars", run: {})
        XCTAssertEqual(registry.purgeAll(), ["avatars", "rows x2"])
        withExtendedLifetime((a, b, c)) {}
    }

    func testLiveInstanceTokenCountsUntilReleased() {
        let registry = MemoryProbeRegistry()
        var first: LiveInstanceToken? = LiveInstanceToken("Chat", registry: registry)
        var second: LiveInstanceToken? = LiveInstanceToken("Chat", registry: registry)
        XCTAssertEqual(registry.snapshot().instances, [.init(name: "Chat", instances: 2, count: 2, bytes: nil)])
        first = nil
        XCTAssertEqual(registry.snapshot().instances.first?.count, 1)
        second = nil
        XCTAssertEqual(registry.snapshot().instances, [])
        _ = (first, second)
    }

    func testDetailReportLine() {
        let memory = ProcessMemory(footprint: 1024 * 1024 * 100, footprintPeak: 0, internalBytes: 1024 * 1024 * 40, compressed: 1024 * 1024 * 60, purgeableVolatile: 0, graphics: 0, media: 0, mallocInUse: 1024 * 1024 * 90)
        let report = MemoryDetailReport(
            memory: memory,
            threads: 41,
            zones: [.init(name: "DefaultMallocZone", bytes: 1024 * 1024 * 90, blocks: 12)],
            caches: [.init(name: "rows", instances: 2, count: 5, bytes: 2 * 1024 * 1024)],
            instances: [.init(name: "ChatControllerNode", instances: 3, count: 3, bytes: nil)]
        )
        XCTAssertEqual(report.logLine, "Memory detail: footprint 100.0 MB (internal 40.0 MB, compressed 60.0 MB, graphics 0.0 MB, media 0.0 MB, malloc 90.0 MB); threads 41; heap by zone [DefaultMallocZone 90.0 MB in 12 blocks]; live objects [ChatControllerNode 3]; caches [rows 5/2.0 MB in 2]")
    }

    func testPurgeReportLine() {
        let memory = ProcessMemory(footprint: 1024 * 1024 * 100, footprintPeak: 0, internalBytes: 0, compressed: 0, purgeableVolatile: 0, graphics: 0, media: 0, mallocInUse: 0)
        let line = MemoryPurgeReport(reason: "background", before: memory, after: nil, purged: ["a", "b"]).logLine
        XCTAssertTrue(line.hasPrefix("Memory purge (background): before footprint 100.0 MB"))
        XCTAssertTrue(line.hasSuffix("after not measured; purged [a, b]"))
    }
}
