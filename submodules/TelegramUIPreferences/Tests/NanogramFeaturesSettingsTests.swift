import XCTest
@testable import TelegramUIPreferences

final class NanogramFeaturesSettingsTests: XCTestCase {
    func testOnDeviceSwitchesAreOffByDefault() {
        XCTAssertFalse(NanogramFeaturesSettings.defaultSettings.onDeviceTranslation)
        XCTAssertFalse(ExperimentalUISettings.defaultSettings.localTranscription)
    }

    func testOnDeviceTranslationIsOffWhenTheKeyIsMissing() throws {
        let settings = try JSONDecoder().decode(NanogramFeaturesSettings.self, from: Data("{\"searchOperators\":true}".utf8))
        XCTAssertFalse(settings.onDeviceTranslation)
        XCTAssertTrue(settings.searchOperators)
    }

    func testOnDeviceTranslationChoiceSurvivesARoundTrip() throws {
        var settings = NanogramFeaturesSettings.defaultSettings
        settings.onDeviceTranslation = true
        let decoded = try JSONDecoder().decode(NanogramFeaturesSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.onDeviceTranslation)
    }

    func testOldTranscriptionDefaultDoesNotCarryOver() throws {
        let blob = Data("{\"localTranscriptionOnDevice\":1}".utf8)
        let settings = try JSONDecoder().decode(ExperimentalUISettings.self, from: blob)
        XCTAssertFalse(settings.localTranscription)
    }
}
