import XCTest
import CoreGraphics
@testable import ChatRowPrep

final class ChatRowPrepKeyTests: XCTestCase {
    typealias Key = ChatRowPrepKey<[Int]>

    private let item = NSObject()
    private let otherItem = NSObject()
    private let theme = NSObject()
    private let otherTheme = NSObject()

    private func base() -> Key {
        return Key(stableId: 7, stableVersion: 3, itemToken: ObjectIdentifier(self.item), width: 390.0, leftInset: 0.0, rightInset: 0.0, neighbors: [1, 2], themeToken: ObjectIdentifier(self.theme), fontSize: 16, interactionEpoch: 10, rotated: true, synchronousLoads: false)
    }

    func testEqualInputsGiveEqualKeys() {
        XCTAssertEqual(self.base(), self.base())
    }

    func testEveryInputChangesTheKey() {
        let reference = self.base()
        var variants: [(String, Key)] = []
        var key = reference
        key.stableId = 8
        variants.append(("stableId", key))
        key = reference
        key.stableVersion = 4
        variants.append(("stableVersion", key))
        key = reference
        key.itemToken = ObjectIdentifier(self.otherItem)
        variants.append(("itemToken", key))
        key = reference
        key.width = 391.0
        variants.append(("width", key))
        key = reference
        key.leftInset = 12.0
        variants.append(("leftInset", key))
        key = reference
        key.rightInset = 12.0
        variants.append(("rightInset", key))
        key = reference
        key.neighbors = [1, 3]
        variants.append(("neighbors", key))
        key = reference
        key.themeToken = ObjectIdentifier(self.otherTheme)
        variants.append(("themeToken", key))
        key = reference
        key.fontSize = 17
        variants.append(("fontSize", key))
        key = reference
        key.interactionEpoch = 11
        variants.append(("interactionEpoch", key))
        key = reference
        key.rotated = false
        variants.append(("rotated", key))
        key = reference
        key.synchronousLoads = true
        variants.append(("synchronousLoads", key))

        // One variant per stored property of the key: adding a field without a variant here fails the count.
        XCTAssertEqual(variants.count, Mirror(reflecting: reference).children.count)
        for (name, variant) in variants {
            XCTAssertNotEqual(reference, variant, "\(name) does not change the key")
        }
    }

    func testNaNWidthNeverMatches() {
        var key = self.base()
        key.width = CGFloat.nan
        XCTAssertNotEqual(key, key)
    }
}
