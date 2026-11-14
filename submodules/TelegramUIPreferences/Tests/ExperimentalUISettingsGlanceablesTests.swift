import XCTest
@testable import TelegramUIPreferences

/// Debug Settings > Glanceables (widget, App Intents, Live Activities) is off for every existing install and for a
/// blob saved by a build that did not know the key.
final class ExperimentalUISettingsGlanceablesTests: XCTestCase {
    func testGlanceablesDecodeToFalseWhenTheKeyIsMissing() throws {
        let settings = try JSONDecoder().decode(ExperimentalUISettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.nanogramGlanceables)
        XCTAssertFalse(ExperimentalUISettings.defaultSettings.nanogramGlanceables)
    }

    func testGlanceablesChoiceSurvivesARoundTrip() throws {
        var settings = ExperimentalUISettings.defaultSettings
        settings.nanogramGlanceables = true
        let decoded = try JSONDecoder().decode(ExperimentalUISettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.nanogramGlanceables)
    }
}
