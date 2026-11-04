import Foundation
import XCTest
@testable import HardenedMedia

private final class CallFlag: @unchecked Sendable {
    var called = false
}

final class LockdownModeDetectionTests: XCTestCase {
    private func defaults(_ value: Bool?) -> UserDefaults {
        let suite = UserDefaults(suiteName: "HardenedMediaTests.\(UUID().uuidString)")!
        if let value {
            suite.set(value, forKey: LockdownMode.legacyDefaultsKey)
        }
        return suite
    }

    func testOfficialAnswerWinsWhenTheAppHoldsTheEntitlement() {
        let on = LockdownModeSources.make(hasStateEntitlement: true, officialAPI: { true }, defaults: defaults(false))
        XCTAssertTrue(LockdownMode.isEnabled(sources: on))
        let off = LockdownModeSources.make(hasStateEntitlement: true, officialAPI: { false }, defaults: defaults(true))
        XCTAssertFalse(LockdownMode.isEnabled(sources: off))
    }

    func testOfficialAPIIsNeverCalledWithoutTheEntitlement() {
        let flag = CallFlag()
        let sources = LockdownModeSources.make(hasStateEntitlement: false, officialAPI: { flag.called = true; return true }, defaults: defaults(nil))
        XCTAssertFalse(LockdownMode.isEnabled(sources: sources))
        XCTAssertFalse(flag.called)
    }

    func testLegacyDefaultsFlagIsTheFallback() {
        XCTAssertTrue(LockdownMode.isEnabled(sources: .make(hasStateEntitlement: false, officialAPI: { false }, defaults: defaults(true))))
        XCTAssertFalse(LockdownMode.isEnabled(sources: .make(hasStateEntitlement: false, officialAPI: { true }, defaults: defaults(false))))
        XCTAssertFalse(LockdownMode.isEnabled(sources: .make(hasStateEntitlement: false, officialAPI: { true }, defaults: defaults(nil))))
    }

    func testOnlyATrueEntitlementValueCountsAsHeld() {
        XCTAssertTrue(LockdownMode.entitlementValueGrantsAccess(kCFBooleanTrue))
        XCTAssertTrue(LockdownMode.entitlementValueGrantsAccess(true))
        XCTAssertFalse(LockdownMode.entitlementValueGrantsAccess(kCFBooleanFalse))
        XCTAssertFalse(LockdownMode.entitlementValueGrantsAccess(false))
        XCTAssertFalse(LockdownMode.entitlementValueGrantsAccess(nil))
        XCTAssertFalse(LockdownMode.entitlementValueGrantsAccess("true"))
        XCTAssertFalse(LockdownMode.entitlementValueGrantsAccess(["true"]))
    }

    func testMissingEntitlementFallsBackWithoutAborting() {
        XCTAssertFalse(LockdownMode.current && !LockdownMode.isEnabled(sources: .system))
    }
}

final class HardenedMediaPolicyTests: XCTestCase {
    func testInactivePolicyChangesNothing() {
        let policy = HardenedMediaPolicy.inactive
        XCTAssertTrue(policy.allowsAutomaticDownload(fromContact: false))
        XCTAssertTrue(policy.allowsAutoplay(fromContact: false))
        XCTAssertTrue(policy.generatesLinkPreviewsForReceivedLinks)
        XCTAssertFalse(policy.confirmsOutgoingLinkPreviews)
        XCTAssertTrue(policy.allowsCodeHighlighting)
        XCTAssertTrue(policy.allowsMiniAppAutoOpen)
    }

    func testLockdownKeepsContactsAndBlocksEveryoneElse() {
        let policy = HardenedMediaPolicy.lockdown
        XCTAssertTrue(policy.allowsAutomaticDownload(fromContact: true))
        XCTAssertFalse(policy.allowsAutomaticDownload(fromContact: false))
        XCTAssertTrue(policy.allowsAutoplay(fromContact: true))
        XCTAssertFalse(policy.allowsAutoplay(fromContact: false))
    }

    func testLockdownTurnsOffPreviewsHighlightingAndMiniAppAutoOpen() {
        let policy = HardenedMediaPolicy.lockdown
        XCTAssertFalse(policy.generatesLinkPreviewsForReceivedLinks)
        XCTAssertTrue(policy.confirmsOutgoingLinkPreviews)
        XCTAssertFalse(policy.allowsCodeHighlighting)
        XCTAssertFalse(policy.allowsMiniAppAutoOpen)
    }

    func testPolicyFollowsTheDetectedState() {
        XCTAssertEqual(HardenedMediaPolicy(lockdownModeEnabled: true), .lockdown)
        XCTAssertEqual(HardenedMediaPolicy(lockdownModeEnabled: false), .inactive)
    }
}

final class VenueSearchPolicyTests: XCTestCase {
    func testChatsSearchNearbyPlacesWithMapKitWhetherOrNotTheUserAsked() {
        for requested in [false, true] {
            XCTAssertEqual(VenueSearchPolicy.backend(isSecretChat: false, isStory: false, userRequested: requested, latitude: 52.5200, longitude: 13.4050), .mapKit)
        }
    }

    func testSecretChatsNeverReachTheBot() {
        for requested in [false, true] {
            for story in [false, true] {
                let backend = VenueSearchPolicy.backend(isSecretChat: true, isStory: story, userRequested: requested, latitude: 52.5200, longitude: 13.4050)
                XCTAssertFalse(backend.usesBot, "secret chat, story \(story), requested \(requested)")
            }
        }
    }

    func testOpeningTheStoryPickerDoesNotQueryTheBot() {
        XCTAssertEqual(VenueSearchPolicy.backend(isSecretChat: false, isStory: true, userRequested: false, latitude: 52.5200, longitude: 13.4050), .none)
    }

    func testAnExplicitStorySearchQueriesTheBotWithCoordinatesRoundedToAboutOneKilometre() {
        let backend = VenueSearchPolicy.backend(isSecretChat: false, isStory: true, userRequested: true, latitude: 52.52437, longitude: 13.40495)
        XCTAssertEqual(backend, .bot(latitude: 52.52, longitude: 13.4))
    }

    func testRoundingSnapsToAHundredthOfADegree() {
        XCTAssertEqual(VenueSearchPolicy.roundedForBot(52.5251), 52.53, accuracy: 1e-9)
        XCTAssertEqual(VenueSearchPolicy.roundedForBot(-33.8688), -33.87, accuracy: 1e-9)
        XCTAssertEqual(VenueSearchPolicy.roundedForBot(0.004), 0.0, accuracy: 1e-9)
    }

    func testTwoPositionsInTheSameCellSendTheSameBotCoordinates() {
        let first = VenueSearchPolicy.backend(isSecretChat: false, isStory: true, userRequested: true, latitude: 40.7121, longitude: -74.0062)
        let second = VenueSearchPolicy.backend(isSecretChat: false, isStory: true, userRequested: true, latitude: 40.7149, longitude: -74.0071)
        XCTAssertEqual(first, second)
    }
}
