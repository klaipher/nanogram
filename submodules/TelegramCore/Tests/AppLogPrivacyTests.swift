import XCTest
@testable import TelegramCore

/// Nothing the app measures about its own use is sent to Telegram.
final class AppLogPrivacyTests: XCTestCase {
    func testNoProductAnalyticsEventMayLeaveTheDevice() {
        let types = [
            "premium_promo_displayed", "premium_promo_clicked", "premium_promo_dismissed",
            "account_deletion_started", "account_deletion_confirmed",
            "ask_for_notifications_permission", "contacts_permission_bucket",
            "download", "network_telemetry_summary", "network_telemetry_failures",
            NetworkTelemetryEvent.summaryType, NetworkTelemetryEvent.failuresType, ""
        ]
        for type in types {
            XCTAssertFalse(appLogEventMayLeaveDevice(type: type), type)
        }
    }

    func testAllowedListIsEmpty() {
        XCTAssertTrue(appLogEventTypesAllowedToLeaveDevice.isEmpty)
    }

    func testReleaseBuildsNeverRecordNetworkTelemetry() {
        let enabled = NetworkTelemetryConfiguration(isEnabled: true, variant: "x", reportInterval: 3600.0)
        let expected = networkTelemetryAlwaysRecords
        #if !DEBUG
        XCTAssertFalse(expected)
        #endif
        XCTAssertEqual(networkTelemetryShouldRecord(supplementary: false, isAppExtension: false, configuration: enabled), expected)
        XCTAssertEqual(networkTelemetryShouldRecord(supplementary: false, isAppExtension: false, configuration: .disabled), expected)
    }
}
