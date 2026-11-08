import XCTest
import UIKit
@testable import Display

/// `FirstResponderLookup` keeps the last first responder found and must answer exactly like the depth-first search
/// (`fullSearch`) whenever it uses the cache.
final class FirstResponderLookupTests: XCTestCase {
    private final class FakeResponder: UIView {
        var responds = false
        override var isFirstResponder: Bool {
            return self.responds
        }
    }

    private final class AccessoryView: UIView, WindowInputAccessoryHeightProvider {
        var height: CGFloat
        init(height: CGFloat) {
            self.height = height
            super.init(frame: CGRect())
        }
        required init?(coder: NSCoder) {
            fatalError()
        }
        func getWindowInputAccessoryHeight() -> CGFloat {
            return self.height
        }
    }

    // root -> a -> accessory(40) -> field ; root -> other
    private func makeTree() -> (root: UIView, accessory: AccessoryView, field: FakeResponder, other: FakeResponder) {
        let root = UIView()
        let a = UIView()
        let accessory = AccessoryView(height: 40.0)
        let field = FakeResponder()
        let other = FakeResponder()
        root.addSubview(a)
        a.addSubview(accessory)
        accessory.addSubview(field)
        root.addSubview(other)
        return (root, accessory, field, other)
    }

    private func assertSame(_ lhs: (UIView?, CGFloat?), _ rhs: (UIView?, CGFloat?), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(lhs.0 === rhs.0, file: file, line: line)
        XCTAssertEqual(lhs.1, rhs.1, file: file, line: line)
    }

    func testCacheHitMatchesTheFullSearchWithoutWalkingTheTree() {
        let (root, _, field, _) = self.makeTree()
        field.responds = true
        let lookup = FirstResponderLookup()
        let first = lookup.find(in: root)
        self.assertSame(first, FirstResponderLookup.fullSearch(root, nil))
        XCTAssertEqual(lookup.fullSearchCount, 1)
        let second = lookup.find(in: root)
        self.assertSame(second, FirstResponderLookup.fullSearch(root, nil))
        XCTAssertEqual(lookup.fullSearchCount, 1, "the second call is a cache hit")
        XCTAssertEqual(second.1, 40.0)
    }

    func testAccessoryHeightIsRecomputedOnACacheHit() {
        let (root, accessory, field, _) = self.makeTree()
        field.responds = true
        let lookup = FirstResponderLookup()
        _ = lookup.find(in: root)
        accessory.height = 72.0
        let hit = lookup.find(in: root)
        XCTAssertEqual(lookup.fullSearchCount, 1)
        self.assertSame(hit, FirstResponderLookup.fullSearch(root, nil))
        XCTAssertEqual(hit.1, 72.0)
    }

    func testDeepestAccessoryProviderWinsAndInitialHeightIsKept() {
        let root = AccessoryView(height: 10.0)
        let inner = AccessoryView(height: 20.0)
        let field = FakeResponder()
        root.addSubview(inner)
        inner.addSubview(field)
        field.responds = true
        let lookup = FirstResponderLookup()
        for _ in 0 ..< 2 {
            self.assertSame(lookup.find(in: root, accessoryHeight: 5.0), FirstResponderLookup.fullSearch(root, 5.0))
        }
        XCTAssertEqual(lookup.fullSearchCount, 1)
        // No provider between root and the responder: the initial height is returned.
        let plain = UIView()
        let plainField = FakeResponder()
        plain.addSubview(plainField)
        plainField.responds = true
        for _ in 0 ..< 2 {
            self.assertSame(lookup.find(in: plain, accessoryHeight: 5.0), FirstResponderLookup.fullSearch(plain, 5.0))
        }
    }

    func testTheRootItselfBeingTheResponder() {
        let root = FakeResponder()
        root.responds = true
        let lookup = FirstResponderLookup()
        for _ in 0 ..< 2 {
            self.assertSame(lookup.find(in: root, accessoryHeight: 7.0), (root, 7.0))
        }
    }

    func testAResponderChangeFallsBackToTheFullSearch() {
        let (root, _, field, other) = self.makeTree()
        field.responds = true
        let lookup = FirstResponderLookup()
        XCTAssertTrue(lookup.find(in: root).0 === field)
        field.responds = false
        other.responds = true
        let moved = lookup.find(in: root)
        XCTAssertEqual(lookup.fullSearchCount, 2)
        XCTAssertTrue(moved.0 === other)
        self.assertSame(moved, FirstResponderLookup.fullSearch(root, nil))
        XCTAssertTrue(lookup.find(in: root).0 === other)
        XCTAssertEqual(lookup.fullSearchCount, 2)
    }

    func testNoResponderGivesNil() {
        let (root, _, field, _) = self.makeTree()
        field.responds = true
        let lookup = FirstResponderLookup()
        _ = lookup.find(in: root)
        field.responds = false
        let result = lookup.find(in: root)
        XCTAssertNil(result.0)
        XCTAssertNil(result.1)
    }

    func testAViewRemovedFromTheTreeIsNotReturned() {
        let (root, _, field, _) = self.makeTree()
        field.responds = true
        let lookup = FirstResponderLookup()
        XCTAssertTrue(lookup.find(in: root).0 === field)
        field.removeFromSuperview()
        let result = lookup.find(in: root)
        XCTAssertNil(result.0, "still reporting first responder, but no longer inside the root")
        self.assertSame(result, FirstResponderLookup.fullSearch(root, nil))
    }

    func testAResponderOutsideTheSearchedSubtreeIsNotReturned() {
        let (root, _, field, _) = self.makeTree()
        field.responds = true
        let lookup = FirstResponderLookup()
        _ = lookup.find(in: root)
        let unrelated = UIView()
        XCTAssertNil(lookup.find(in: unrelated).0)
    }

    func testTheCacheDoesNotRetainTheView() {
        let lookup = FirstResponderLookup()
        weak var weakField: FakeResponder?
        let root = UIView()
        autoreleasepool {
            let field = FakeResponder()
            field.responds = true
            root.addSubview(field)
            weakField = field
            _ = lookup.find(in: root)
            field.removeFromSuperview()
        }
        XCTAssertNil(weakField)
    }
}
