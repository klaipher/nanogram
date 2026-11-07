import Foundation
import XCTest
import SwiftSignalKit
@testable import Postbox

/// A preference or a cache entry stored again with the bytes it already has writes nothing and is no change for the
/// views: the transaction is empty. A different value is stored as before.
final class PostboxIdenticalStoreWriteTests: XCTestCase {
    private var fixture: PostboxFixture!

    override func setUp() {
        super.setUp()
        self.fixture = PostboxFixture(name: "PostboxIdenticalStoreWriteTests")
    }

    override func tearDown() {
        self.fixture?.close()
        self.fixture = nil
        super.tearDown()
    }

    private func key(_ name: String) -> ValueBoxKey {
        let key = ValueBoxKey(length: 1)
        key.setUInt8(0, value: UInt8(name.utf8.first ?? 0))
        return key
    }

    // MARK: - Preferences

    func testStoringTheSamePreferenceIsAnEmptyTransaction() {
        let key = self.key("a")
        self.fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: Data([1, 2, 3])))
        }
        let before = self.fixture.writeTransactionCount()
        self.fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: Data([1, 2, 3])))
        }
        XCTAssertEqual(self.fixture.writeTransactionCount(), before, "the same preference must not be written")

        self.fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: Data([1, 2, 4])))
        }
        XCTAssertEqual(self.fixture.writeTransactionCount(), before + 1)
        let stored = self.fixture.transaction { transaction in
            return transaction.getPreferencesEntry(key: key)?.data
        }
        XCTAssertEqual(stored ?? nil, Data([1, 2, 4]))
    }

    func testRemovingAMissingPreferenceIsAnEmptyTransaction() {
        let key = self.key("b")
        let before = self.fixture.writeTransactionCount()
        self.fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: nil)
        }
        XCTAssertEqual(self.fixture.writeTransactionCount(), before)

        self.fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: Data([9])))
        }
        self.fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: nil)
        }
        let stored = self.fixture.transaction { transaction in
            return transaction.getPreferencesEntry(key: key)?.data
        }
        XCTAssertNil(stored ?? nil)
    }

    func testAPreferenceChangedAndRestoredInOneTransactionIsStoredAsRestored() {
        let key = self.key("c")
        self.fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: Data([1])))
        }
        self.fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: Data([2])))
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: Data([1])))
        }
        let stored = self.fixture.transaction { transaction in
            return transaction.getPreferencesEntry(key: key)?.data
        }
        XCTAssertEqual(stored ?? nil, Data([1]))
    }

    func testAChangedPreferenceStillReachesItsView() {
        let key = self.key("d")
        self.fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: Data([1])))
        }
        let recorder = self.fixture.observe(.preferences(keys: Set([key])), as: PreferencesView.self)
        recorder.waitForValues(count: 1)
        self.fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: Data([1])))
        }
        self.fixture.transaction { _ in }
        XCTAssertEqual(recorder.values.count, 1, "the same value is no change")
        self.fixture.transaction { transaction in
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: Data([2])))
        }
        recorder.waitForValues(count: 2)
    }

    // MARK: - Item cache

    func testStoringTheSameCacheEntryIsAnEmptyTransaction() {
        let id = ItemCacheEntryId(collectionId: 7, key: self.key("e"))
        self.fixture.transaction { transaction in
            transaction.putItemCacheEntry(id: id, entry: CodableEntry(data: Data([5, 6, 7])))
        }
        let before = self.fixture.writeTransactionCount()
        self.fixture.transaction { transaction in
            transaction.putItemCacheEntry(id: id, entry: CodableEntry(data: Data([5, 6, 7])))
        }
        XCTAssertEqual(self.fixture.writeTransactionCount(), before, "the same cache entry must not be written")

        self.fixture.transaction { transaction in
            transaction.putItemCacheEntry(id: id, entry: CodableEntry(data: Data([5, 6, 8])))
        }
        XCTAssertEqual(self.fixture.writeTransactionCount(), before + 1)
        let stored = self.fixture.transaction { transaction in
            return transaction.retrieveItemCacheEntry(id: id)?.data
        }
        XCTAssertEqual(stored ?? nil, Data([5, 6, 8]))
    }

    func testACacheEntryOfADifferentLengthIsStored() {
        let id = ItemCacheEntryId(collectionId: 7, key: self.key("f"))
        self.fixture.transaction { transaction in
            transaction.putItemCacheEntry(id: id, entry: CodableEntry(data: Data([1, 2])))
        }
        self.fixture.transaction { transaction in
            transaction.putItemCacheEntry(id: id, entry: CodableEntry(data: Data([1, 2, 3])))
        }
        let stored = self.fixture.transaction { transaction in
            return transaction.retrieveItemCacheEntry(id: id)?.data
        }
        XCTAssertEqual(stored ?? nil, Data([1, 2, 3]))
    }

    func testAnEmptyCacheEntryStoredTwiceIsAnEmptyTransaction() {
        let id = ItemCacheEntryId(collectionId: 7, key: self.key("g"))
        self.fixture.transaction { transaction in
            transaction.putItemCacheEntry(id: id, entry: CodableEntry(data: Data()))
        }
        let before = self.fixture.writeTransactionCount()
        self.fixture.transaction { transaction in
            transaction.putItemCacheEntry(id: id, entry: CodableEntry(data: Data()))
        }
        XCTAssertEqual(self.fixture.writeTransactionCount(), before)
    }
}
