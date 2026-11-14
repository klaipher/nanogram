import XCTest
@testable import tgwatch_Watch_App

/// WATCH-I18N-1: the language, application and system version sent in setTdlibParameters.
final class CoreTdlibSystemInfoTests: XCTestCase {
    func testLegacyValuesAreTheOldFixedOnes() {
        XCTAssertEqual(TdlibSystemInfo.legacy, TdlibSystemInfo(languageCode: "en", applicationVersion: "0.1", systemVersion: nil))
    }

    func testLanguageCodeIsTheLanguageOfTheFirstPreferredLanguage() {
        XCTAssertEqual(TdlibSystemInfo.languageCode(preferredLanguages: ["uk-UA", "en-US"]), "uk")
        XCTAssertEqual(TdlibSystemInfo.languageCode(preferredLanguages: ["pt-BR"]), "pt")
        XCTAssertEqual(TdlibSystemInfo.languageCode(preferredLanguages: ["zh-Hans-CN"]), "zh")
        XCTAssertEqual(TdlibSystemInfo.languageCode(preferredLanguages: ["de"]), "de")
    }

    func testNoPreferredLanguageFallsBackToEnglish() {
        XCTAssertEqual(TdlibSystemInfo.languageCode(preferredLanguages: []), "en")
        XCTAssertEqual(TdlibSystemInfo.languageCode(preferredLanguages: [""]), "en")
    }

    func testMakeUsesTheBundleAndSystemVersion() {
        let info = TdlibSystemInfo.make(preferredLanguages: ["fr-FR"], shortVersion: "13.2", systemVersion: "26.1")
        XCTAssertEqual(info, TdlibSystemInfo(languageCode: "fr", applicationVersion: "13.2", systemVersion: "26.1"))
    }

    func testMissingVersionsFallBack() {
        let info = TdlibSystemInfo.make(preferredLanguages: ["fr"], shortVersion: nil, systemVersion: "")
        XCTAssertEqual(info.applicationVersion, "0.1")
        XCTAssertNil(info.systemVersion, "empty means TDLib detects it")
        XCTAssertEqual(TdlibSystemInfo.make(preferredLanguages: [], shortVersion: "", systemVersion: nil).applicationVersion, "0.1")
    }

    @MainActor
    func testFlagOffSendsTheLegacyValuesWhateverTheDevice() {
        XCTAssertEqual(TdlibSystemInfo.resolve(enabled: false), .legacy)
    }

    @MainActor
    func testFlagOnSendsTheDeviceValues() {
        let info = TdlibSystemInfo.resolve(enabled: true)
        XCTAssertFalse(info.languageCode.isEmpty)
        XCTAssertFalse(info.applicationVersion.isEmpty)
        XCTAssertNotNil(info.systemVersion)
    }

    func testFlagShipsOff() {
        XCTAssertFalse(WatchFeature.localizedTdlibParameters.defaultValue)
    }
}
