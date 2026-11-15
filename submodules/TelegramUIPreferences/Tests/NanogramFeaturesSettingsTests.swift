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

    func testVoiceEnhancementIsOffByDefault() {
        XCTAssertFalse(NanogramFeaturesSettings.defaultSettings.voiceEnhancement)
    }

    func testVoiceEnhancementIsOffWhenTheKeyIsMissing() throws {
        let settings = try JSONDecoder().decode(NanogramFeaturesSettings.self, from: Data("{\"searchOperators\":true,\"onDeviceTranslation\":true}".utf8))
        XCTAssertFalse(settings.voiceEnhancement)
        XCTAssertTrue(settings.onDeviceTranslation)
    }

    func testVoiceEnhancementChoiceSurvivesARoundTrip() throws {
        var settings = NanogramFeaturesSettings.defaultSettings
        settings.voiceEnhancement = true
        let decoded = try JSONDecoder().decode(NanogramFeaturesSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.voiceEnhancement)
        XCTAssertEqual(decoded, settings)
    }
}
