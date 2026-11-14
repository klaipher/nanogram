import XCTest
import InAppPurchaseManager

final class StorePurchasePolicyTests: XCTestCase {
    private let purchases: [StorePurchasePolicy.EntryPoint] = [
        .premiumSubscription, .premiumGiftPurchase, .premiumGiveawayPurchase, .starsTopUp,
        .starsGiftPurchase, .paidBoostPurchase, .storeKitProductRequests, .receiptRestore
    ]

    func testStoreBuildBlocksEveryPurchase() {
        let policy = StorePurchasePolicy(isStoreBuild: true)
        for entryPoint in self.purchases {
            XCTAssertFalse(policy.allows(entryPoint), "\(entryPoint)")
        }
        XCTAssertFalse(policy.sellsPremium)
        XCTAssertFalse(policy.sellsStars)
    }

    func testStoreBuildKeepsWhatTheUserAlreadyHas() {
        let policy = StorePurchasePolicy(isStoreBuild: true)
        for entryPoint in StorePurchasePolicy.EntryPoint.allCases where !self.purchases.contains(entryPoint) {
            XCTAssertTrue(policy.allows(entryPoint), "\(entryPoint)")
        }
    }

    func testNonStoreBuildAllowsEverything() {
        let policy = StorePurchasePolicy(isStoreBuild: false)
        for entryPoint in StorePurchasePolicy.EntryPoint.allCases {
            XCTAssertTrue(policy.allows(entryPoint), "\(entryPoint)")
        }
    }

    func testDefaultBuildIsStoreBuild() {
        XCTAssertTrue(StorePurchasePolicy.current.isStoreBuild)
    }
}
