import XCTest
import TelegramUIPreferences
@testable import TelegramCallsUI

final class CallKitPrivacyTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "CallKitPrivacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    func testCallsShowInRecentsUnlessTheUserTurnedItOff() {
        let defaults = self.makeDefaults()
        XCTAssertTrue(CallKitPrivacy.showCallsInRecents(defaults: defaults))
        CallKitPrivacy.storeShowCallsInRecents(false, defaults: defaults)
        XCTAssertFalse(CallKitPrivacy.showCallsInRecents(defaults: defaults))
        CallKitPrivacy.storeShowCallsInRecents(true, defaults: defaults)
        XCTAssertTrue(CallKitPrivacy.showCallsInRecents(defaults: defaults))
    }

    func testOutgoingCallIsDonatedToSiriOnlyWithoutPasscodeAndWithRecentsOn() {
        XCTAssertTrue(CallKitPrivacy.shouldDonateOutgoingCall(isUnprotected: true, showCallsInRecents: true))
        XCTAssertFalse(CallKitPrivacy.shouldDonateOutgoingCall(isUnprotected: false, showCallsInRecents: true))
        XCTAssertFalse(CallKitPrivacy.shouldDonateOutgoingCall(isUnprotected: true, showCallsInRecents: false))
        XCTAssertFalse(CallKitPrivacy.shouldDonateOutgoingCall(isUnprotected: false, showCallsInRecents: false))
    }

    func testVoiceCallSettingsShowCallsInRecentsByDefault() {
        XCTAssertTrue(VoiceCallSettings.defaultSettings.showCallsInRecents)
    }

    func testSettingsStoredBeforeTheOptionExistedDecodeAsShowing() throws {
        let legacy = try JSONEncoder().encode(["ds": 3, "enableSystemIntegration": 1])
        let decoded = try JSONDecoder().decode(VoiceCallSettings.self, from: legacy)
        XCTAssertTrue(decoded.showCallsInRecents)
        XCTAssertTrue(decoded.enableSystemIntegration)
    }

    func testTheOptionSurvivesEncodingAndDecoding() throws {
        var settings = VoiceCallSettings.defaultSettings
        settings.showCallsInRecents = false
        let decoded = try JSONDecoder().decode(VoiceCallSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.showCallsInRecents)
        XCTAssertEqual(decoded, settings)
    }
}
