import XCTest
import TelegramCore
import InAppPurchaseManager
import AccountContext

final class PremiumConfigurationTests: XCTestCase {
    private func configuration(blocked: Bool?) throws -> AppConfiguration {
        var configuration = AppConfiguration.defaultValue
        configuration.data = try XCTUnwrap(JSON(dictionary: blocked.map { ["premium_purchase_blocked": $0] } ?? [:]))
        return configuration
    }

    func testStoreBuildHidesPurchasesButKeepsDisplayWhenServerAllowsPremium() throws {
        let configuration = PremiumConfiguration.with(appConfiguration: try self.configuration(blocked: false), policy: StorePurchasePolicy(isStoreBuild: true))
        XCTAssertTrue(configuration.isPremiumDisabled)
        XCTAssertFalse(configuration.isPremiumDisplayDisabled)
    }

    func testServerBlockDisablesBoth() throws {
        let configuration = PremiumConfiguration.with(appConfiguration: try self.configuration(blocked: true), policy: StorePurchasePolicy(isStoreBuild: true))
        XCTAssertTrue(configuration.isPremiumDisabled)
        XCTAssertTrue(configuration.isPremiumDisplayDisabled)
    }

    func testStoreBuildWithoutServerKeyKeepsDisplay() throws {
        let configuration = PremiumConfiguration.with(appConfiguration: try self.configuration(blocked: nil), policy: StorePurchasePolicy(isStoreBuild: true))
        XCTAssertTrue(configuration.isPremiumDisabled)
        XCTAssertFalse(configuration.isPremiumDisplayDisabled)
    }

    func testNonStoreBuildFollowsTheServerOnly() throws {
        let allowed = PremiumConfiguration.with(appConfiguration: try self.configuration(blocked: false), policy: StorePurchasePolicy(isStoreBuild: false))
        XCTAssertFalse(allowed.isPremiumDisabled)
        XCTAssertFalse(allowed.isPremiumDisplayDisabled)
        let blocked = PremiumConfiguration.with(appConfiguration: try self.configuration(blocked: true), policy: StorePurchasePolicy(isStoreBuild: false))
        XCTAssertTrue(blocked.isPremiumDisabled)
        XCTAssertTrue(blocked.isPremiumDisplayDisabled)
    }
}
