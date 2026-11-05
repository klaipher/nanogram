import Foundation
import XCTest
import Postbox
@testable import TelegramCore

/// The automatic cache eviction runs once a day at most, unless its limits change: the fingerprint of the limits
/// decides.
final class AutomaticCacheEvictionFingerprintTests: XCTestCase {
    private func fingerprint(_ categories: [CacheStorageSettings.PeerStorageCategory: Int32], _ exceptions: [(Int64, Int32)] = []) -> String {
        return automaticCacheEvictionFingerprint(
            categoryStorageTimeout: categories,
            exceptions: exceptions.map { AccountSpecificCacheStorageSettings.Value(key: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value($0.0)), value: $0.1) }
        )
    }

    func testTheSameLimitsGiveTheSameFingerprintInAnyOrder() {
        let a = self.fingerprint([.privateChats: 100, .groups: 200, .channels: 300], [(1, 10), (2, 20)])
        let b = self.fingerprint([.channels: 300, .groups: 200, .privateChats: 100], [(2, 20), (1, 10)])
        XCTAssertEqual(a, b)
    }

    func testAChangedLimitChangesTheFingerprint() {
        let base = self.fingerprint([.privateChats: 100, .groups: 200], [(1, 10)])
        XCTAssertNotEqual(base, self.fingerprint([.privateChats: 101, .groups: 200], [(1, 10)]))
        XCTAssertNotEqual(base, self.fingerprint([.privateChats: 100], [(1, 10)]))
        XCTAssertNotEqual(base, self.fingerprint([.privateChats: 100, .groups: 200], [(1, 11)]))
        XCTAssertNotEqual(base, self.fingerprint([.privateChats: 100, .groups: 200], []))
    }

    private func shortest(_ categories: [CacheStorageSettings.PeerStorageCategory: Int32], _ exceptions: [(Int64, Int32)] = []) -> Int32 {
        return automaticCacheEvictionShortestStoreTime(
            categoryStorageTimeout: categories,
            exceptions: exceptions.map { AccountSpecificCacheStorageSettings.Value(key: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value($0.0)), value: $0.1) }
        )
    }

    // The cache touches keep the modification time fresh enough for the shortest of these keep times.
    func testTheShortestStoreTimeCoversCategoriesStoriesAndExceptions() {
        XCTAssertEqual(self.shortest(CacheStorageSettings.defaultSettings.categoryStorageTimeout), 2 * 86_400)
        // Stories missing from the settings are evicted after 2 days, as in the eviction itself.
        XCTAssertEqual(self.shortest([.privateChats: Int32.max, .channels: 7 * 86_400]), 2 * 86_400)
        XCTAssertEqual(self.shortest([.stories: Int32.max, .channels: 86_400]), 86_400)
        XCTAssertEqual(self.shortest([.stories: Int32.max], [(1, 3 * 86_400), (2, 86_400)]), 86_400)
        XCTAssertEqual(self.shortest([.stories: Int32.max]), Int32.max)
    }
}
