import Foundation
import XCTest
@testable import EntityKeyboard

final class EmojiItemReuseCacheTests: XCTestCase {
    private final class Box {
        let name: String

        init(_ name: String) {
            self.name = name
        }
    }

    private typealias Cache = EmojiItemReuseCache<String, Int, Box>

    private func build(_ cache: Cache, _ items: [(key: String, fingerprint: Int)]) -> (values: [Box], built: Int, reused: Int) {
        var pass = cache.beginPass()
        let values = items.map { item in
            pass.value(for: item.key, fingerprint: item.fingerprint, make: { Box(item.key) })
        }
        cache.commit(pass)
        return (values, pass.builtCount, pass.reusedCount)
    }

    func testSameInputGivesTheSameInstances() {
        let cache = Cache()
        let input = [(key: "a", fingerprint: 1), (key: "b", fingerprint: 1), (key: "c", fingerprint: 1)]
        let first = self.build(cache, input)
        let second = self.build(cache, input)
        XCTAssertEqual(first.built, 3)
        XCTAssertEqual(second.built, 0)
        XCTAssertEqual(second.reused, 3)
        for (lhs, rhs) in zip(first.values, second.values) {
            XCTAssertTrue(lhs === rhs)
        }
    }

    func testOneChangedEntryBuildsOneValue() {
        let cache = Cache()
        let first = self.build(cache, [(key: "a", fingerprint: 1), (key: "b", fingerprint: 1), (key: "c", fingerprint: 1)])
        let second = self.build(cache, [(key: "a", fingerprint: 1), (key: "b", fingerprint: 2), (key: "c", fingerprint: 1)])
        XCTAssertEqual(second.built, 1)
        XCTAssertEqual(second.reused, 2)
        XCTAssertTrue(first.values[0] === second.values[0])
        XCTAssertFalse(first.values[1] === second.values[1])
        XCTAssertTrue(first.values[2] === second.values[2])
    }

    func testEntriesOfAnEarlierPassAreDropped() {
        let cache = Cache()
        let _ = self.build(cache, [(key: "a", fingerprint: 1), (key: "b", fingerprint: 1)])
        let _ = self.build(cache, [(key: "a", fingerprint: 1)])
        XCTAssertEqual(cache.count, 1)
        // "b" was dropped, so it is built again.
        let third = self.build(cache, [(key: "a", fingerprint: 1), (key: "b", fingerprint: 1)])
        XCTAssertEqual(third.built, 1)
    }

    func testAPassThatIsNotCommittedChangesNothing() {
        let cache = Cache()
        let first = self.build(cache, [(key: "a", fingerprint: 1)])
        var abandoned = cache.beginPass()
        let _ = abandoned.value(for: "a", fingerprint: 2, make: { Box("a2") })
        let second = self.build(cache, [(key: "a", fingerprint: 1)])
        XCTAssertTrue(first.values[0] === second.values[0])
    }

    func testDuplicateKeyInOnePassSharesTheValue() {
        let cache = Cache()
        let result = self.build(cache, [(key: "a", fingerprint: 1), (key: "a", fingerprint: 1)])
        XCTAssertEqual(result.built, 1)
        XCTAssertTrue(result.values[0] === result.values[1])
    }
}

final class EmojiReuseIdentityFingerprintTests: XCTestCase {
    private final class Child {
        let id: Int

        init(_ id: Int) {
            self.id = id
        }
    }

    private struct LooseValue: Equatable {
        let title: String
        let childIds: [Int]
    }

    private typealias Fingerprint = EmojiReuseIdentityFingerprint<LooseValue, Child>

    func testSameChildInstancesAndEqualValueMatch() {
        let children = [Child(1), Child(2)]
        let lhs = Fingerprint(value: LooseValue(title: "a", childIds: [1, 2]), children: children)
        let rhs = Fingerprint(value: LooseValue(title: "a", childIds: [1, 2]), children: children)
        XCTAssertEqual(lhs, rhs)
    }

    func testRebuiltChildThatOnlyComparesEqualDoesNotMatch() {
        let first = Child(1)
        let second = Child(2)
        let rebuiltSecond = Child(2)
        let lhs = Fingerprint(value: LooseValue(title: "a", childIds: [1, 2]), children: [first, second])
        let rhs = Fingerprint(value: LooseValue(title: "a", childIds: [1, 2]), children: [first, rebuiltSecond])
        XCTAssertNotEqual(lhs, rhs)
    }

    func testChangedValueDoesNotMatch() {
        let children = [Child(1)]
        let lhs = Fingerprint(value: LooseValue(title: "a", childIds: [1]), children: children)
        let rhs = Fingerprint(value: LooseValue(title: "b", childIds: [1]), children: children)
        XCTAssertNotEqual(lhs, rhs)
    }

    func testDifferentChildCountDoesNotMatch() {
        let child = Child(1)
        let lhs = Fingerprint(value: LooseValue(title: "a", childIds: [1]), children: [child])
        let rhs = Fingerprint(value: LooseValue(title: "a", childIds: [1]), children: [child, child])
        XCTAssertNotEqual(lhs, rhs)
    }

    func testGroupWithARebuiltChildIsBuiltAgainInTheCache() {
        let cache = EmojiItemReuseCache<String, Fingerprint, LooseValue>()
        let first = Child(1)
        var pass = cache.beginPass()
        let _ = pass.value(for: "g", fingerprint: Fingerprint(value: LooseValue(title: "a", childIds: [1]), children: [first]), make: { LooseValue(title: "a", childIds: [1]) })
        cache.commit(pass)

        var samePass = cache.beginPass()
        let _ = samePass.value(for: "g", fingerprint: Fingerprint(value: LooseValue(title: "a", childIds: [1]), children: [first]), make: { LooseValue(title: "a", childIds: [1]) })
        XCTAssertEqual(samePass.reusedCount, 1)
        cache.commit(samePass)

        var rebuiltPass = cache.beginPass()
        let _ = rebuiltPass.value(for: "g", fingerprint: Fingerprint(value: LooseValue(title: "a", childIds: [1]), children: [Child(1)]), make: { LooseValue(title: "a", childIds: [1]) })
        XCTAssertEqual(rebuiltPass.builtCount, 1)
        XCTAssertEqual(rebuiltPass.reusedCount, 0)
    }
}
