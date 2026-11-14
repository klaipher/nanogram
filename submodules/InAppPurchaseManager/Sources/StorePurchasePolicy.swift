import Foundation

/// The one switch that keeps Telegram's own in-app products (Premium, Stars top-ups, Premium gifts and
/// giveaways, paid boosts) out of store builds. App Review 3.1.1 and the Play payments policy do not allow
/// a fork to sell them. A non-store build defines NANOGRAM_PURCHASES_ENABLED to turn them back on.
public struct StorePurchasePolicy: Equatable {
    public enum EntryPoint: CaseIterable {
        case premiumSubscription
        case premiumGiftPurchase
        case premiumGiveawayPurchase
        case starsTopUp
        case starsGiftPurchase
        case paidBoostPurchase
        case tonTopUp
        case storeKitProductRequests
        case receiptRestore

        // Never sold through Telegram's store products, so never blocked.
        case viewPremiumStatus
        case usePremiumFeatures
        case spendOwnedStars
        case receiveOrConvertGift
        case physicalGoodsPayment
        case redeemGiftCode
    }

    public static let current = StorePurchasePolicy(isStoreBuild: StorePurchasePolicy.buildIsStoreBuild)

    private static var buildIsStoreBuild: Bool {
        #if NANOGRAM_PURCHASES_ENABLED
        return false
        #else
        return true
        #endif
    }

    public let isStoreBuild: Bool

    public init(isStoreBuild: Bool) {
        self.isStoreBuild = isStoreBuild
    }

    public func allows(_ entryPoint: EntryPoint) -> Bool {
        switch entryPoint {
        case .premiumSubscription, .premiumGiftPurchase, .premiumGiveawayPurchase, .starsTopUp, .starsGiftPurchase, .paidBoostPurchase, .tonTopUp, .storeKitProductRequests, .receiptRestore:
            return !self.isStoreBuild
        case .viewPremiumStatus, .usePremiumFeatures, .spendOwnedStars, .receiveOrConvertGift, .physicalGoodsPayment, .redeemGiftCode:
            return true
        }
    }

    public var sellsPremium: Bool {
        return self.allows(.premiumSubscription)
    }

    public var sellsStars: Bool {
        return self.allows(.starsTopUp)
    }
}
