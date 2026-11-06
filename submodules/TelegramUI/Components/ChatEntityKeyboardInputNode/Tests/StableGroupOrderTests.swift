import XCTest
import Postbox
@testable import ChatEntityKeyboardInputNode

final class StableGroupOrderTests: XCTestCase {
    private struct TestGroup: Equatable {
        var id: AnyHashable
        var isEmbedded = false
        var isFeatured = false
    }

    private func pack(_ id: Int64) -> ItemCollectionId {
        return ItemCollectionId(namespace: 1, id: id)
    }

    private func group(_ id: Int64, embedded: Bool = false, featured: Bool = false) -> TestGroup {
        return TestGroup(id: AnyHashable(self.pack(id)), isEmbedded: embedded, isFeatured: featured)
    }

    private func named(_ name: String) -> TestGroup {
        return TestGroup(id: AnyHashable(name))
    }

    /// The previous implementation, kept verbatim as the reference.
    private func reference(groups: [TestGroup], stored: [ItemCollectionId]?) -> (groups: [TestGroup], order: [ItemCollectionId]) {
        func collectionId(_ group: TestGroup) -> ItemCollectionId? {
            if group.isEmbedded || group.isFeatured {
                return nil
            }
            return group.id.base as? ItemCollectionId
        }
        let nextIds = groups.compactMap(collectionId)
        let stableOrder = stored ?? nextIds
        var updatedGroups: [TestGroup] = []
        var staticIsFirst = false
        let topStaticGroups: [String] = ["static", "recent", "featuredTop"]
        for group in groups {
            var found = false
            for topStaticGroup in topStaticGroups {
                if group.id == AnyHashable(topStaticGroup) {
                    if group.id == AnyHashable("static") {
                        staticIsFirst = true
                    }
                    found = true
                    break
                }
            }
            if !found {
                break
            }
        }
        for group in groups {
            if !(group.id.base is ItemCollectionId) {
                if group.id != AnyHashable("static") || staticIsFirst {
                    updatedGroups.append(group)
                }
            } else {
                if group.isEmbedded {
                    continue
                }
                if group.isFeatured {
                    continue
                }
                if !stableOrder.contains(where: { AnyHashable($0) == group.id }) {
                    updatedGroups.append(group)
                }
            }
        }
        for id in stableOrder {
            if let group = groups.first(where: { $0.id == AnyHashable(id) }) {
                updatedGroups.append(group)
            }
        }
        for group in groups {
            if !updatedGroups.contains(where: { $0.id == group.id }) {
                updatedGroups.append(group)
            }
        }
        return (updatedGroups, updatedGroups.compactMap(collectionId))
    }

    private func run(_ groups: [TestGroup], stored: [ItemCollectionId]?) -> (groups: [TestGroup], order: [ItemCollectionId]) {
        return StableGroupOrder.process(groups: groups, storedOrder: stored, id: { $0.id }, isEmbedded: { $0.isEmbedded }, isFeatured: { $0.isFeatured }, collectionId: { $0.base as? ItemCollectionId })
    }

    private func assertSame(_ groups: [TestGroup], stored: [ItemCollectionId]?, file: StaticString = #filePath, line: UInt = #line) {
        let expected = self.reference(groups: groups, stored: stored)
        let actual = self.run(groups, stored: stored)
        XCTAssertEqual(actual.groups, expected.groups, file: file, line: line)
        XCTAssertEqual(actual.order, expected.order, file: file, line: line)
    }

    func testFirstCallKeepsOrderAndStoresIt() {
        let groups = [self.named("static"), self.named("recent"), self.group(1), self.group(2), self.group(3)]
        let result = self.run(groups, stored: nil)
        XCTAssertEqual(result.groups, groups)
        XCTAssertEqual(result.order, [self.pack(1), self.pack(2), self.pack(3)])
        self.assertSame(groups, stored: nil)
    }

    func testStoredOrderWinsAndNewPacksComeFirst() {
        let groups = [self.named("recent"), self.group(1), self.group(2), self.group(3), self.group(4)]
        self.assertSame(groups, stored: [self.pack(3), self.pack(1), self.pack(2)])
        let result = self.run(groups, stored: [self.pack(3), self.pack(1), self.pack(2)])
        XCTAssertEqual(result.order, [self.pack(4), self.pack(3), self.pack(1), self.pack(2)])
    }

    func testRemovedPackIsDroppedFromStoredOrder() {
        let groups = [self.group(1), self.group(3)]
        let result = self.run(groups, stored: [self.pack(3), self.pack(2), self.pack(1)])
        XCTAssertEqual(result.order, [self.pack(3), self.pack(1)])
        self.assertSame(groups, stored: [self.pack(3), self.pack(2), self.pack(1)])
    }

    func testEmbeddedAndFeaturedGroupsAreNotReorderable() {
        let groups = [self.group(1), self.group(2, embedded: true), self.group(3, featured: true), self.group(4)]
        let result = self.run(groups, stored: nil)
        XCTAssertEqual(result.order, [self.pack(1), self.pack(4)])
        self.assertSame(groups, stored: nil)
        self.assertSame(groups, stored: [self.pack(4), self.pack(2), self.pack(1)])
    }

    func testStaticGroupIsDroppedUnlessItLeadsTheList() {
        self.assertSame([self.group(1), self.named("static"), self.group(2)], stored: nil)
        self.assertSame([self.named("recent"), self.named("static"), self.group(2)], stored: nil)
        self.assertSame([self.named("featuredTop"), self.group(2), self.named("static")], stored: nil)
    }

    func testDuplicateGroupIdsMatchTheFormerBehaviour() {
        self.assertSame([self.group(1), self.group(1), self.group(2)], stored: [self.pack(2), self.pack(1)])
        self.assertSame([self.named("x"), self.named("x"), self.group(5)], stored: nil)
    }

    func testRandomListsMatchTheFormerImplementation() {
        var seed: UInt64 = 0x1234_5678
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: (seed >> 33) % UInt64(bound))
        }
        for _ in 0 ..< 300 {
            var groups: [TestGroup] = []
            for _ in 0 ..< next(14) {
                switch next(7) {
                case 0: groups.append(self.named("static"))
                case 1: groups.append(self.named("recent"))
                case 2: groups.append(self.named("featuredTop"))
                case 3: groups.append(self.group(Int64(next(6)), embedded: true))
                case 4: groups.append(self.group(Int64(next(6)), featured: true))
                default: groups.append(self.group(Int64(next(6))))
                }
            }
            var stored: [ItemCollectionId]?
            if next(3) != 0 {
                var order: [ItemCollectionId] = []
                for _ in 0 ..< next(8) {
                    order.append(self.pack(Int64(next(8))))
                }
                stored = order
            }
            self.assertSame(groups, stored: stored)
        }
    }

    func testLargeListRunsInLinearTime() {
        var groups: [TestGroup] = [self.named("static")]
        for index in 0 ..< 3000 {
            groups.append(self.group(Int64(index)))
        }
        let stored = groups.compactMap { $0.id.base as? ItemCollectionId }.reversed()
        let start = CFAbsoluteTimeGetCurrent()
        let result = self.run(groups, stored: Array(stored))
        XCTAssertEqual(result.groups.count, groups.count)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 1.0)
    }
}
