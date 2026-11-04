import XCTest
import HardenedMedia
@testable import TelegramUIPreferences

final class MediaAutoDownloadHardeningTests: XCTestCase {
    func testLockdownDropsEveryNonContactCategoryAndKeepsContacts() {
        let settings = MediaAutoDownloadSettings.defaultSettings.hardened(by: .lockdown)
        for categories in [settings.presets.low, settings.presets.medium, settings.presets.high] {
            for category in [categories.photo, categories.video, categories.file, categories.stories] {
                XCTAssertFalse(category.otherPrivate)
                XCTAssertFalse(category.groups)
                XCTAssertFalse(category.channels)
            }
        }
        XCTAssertTrue(settings.presets.high.photo.contacts)
        XCTAssertTrue(settings.presets.medium.video.contacts)
    }

    func testLockdownTurnsOffAutoplayAndLooping() {
        var settings = MediaAutoDownloadSettings.defaultSettings
        settings.energyUsageSettings.autoplayVideo = true
        settings.energyUsageSettings.autoplayGif = true
        settings.energyUsageSettings.loopStickers = true
        settings.energyUsageSettings.loopEmoji = true
        let hardened = settings.hardened(by: .lockdown)
        XCTAssertFalse(hardened.energyUsageSettings.autoplayVideo)
        XCTAssertFalse(hardened.energyUsageSettings.autoplayGif)
        XCTAssertFalse(hardened.energyUsageSettings.loopStickers)
        XCTAssertFalse(hardened.energyUsageSettings.loopEmoji)
    }

    func testCustomCategoriesAreHardenedToo() {
        var settings = MediaAutoDownloadSettings.defaultSettings
        settings.wifi = MediaAutoDownloadConnection(enabled: true, preset: .custom, custom: settings.presets.high)
        let hardened = settings.hardened(by: .lockdown)
        XCTAssertEqual(hardened.wifi.custom?.video.groups, false)
        XCTAssertEqual(hardened.wifi.custom?.video.contacts, true)
    }

    func testAnInactivePolicyLeavesTheSettingsAlone() {
        let settings = MediaAutoDownloadSettings.defaultSettings
        XCTAssertEqual(settings.hardened(by: .inactive), settings)
    }

    func testNoAutomaticDownloadFromANonContactUnderLockdown() {
        let settings = MediaAutoDownloadSettings.defaultSettings
        XCTAssertFalse(shouldDownloadMediaAutomatically(settings: settings, peerType: .otherPrivate, networkType: .wifi, media: nil, hardenedPolicy: .lockdown))
        XCTAssertFalse(shouldDownloadMediaAutomatically(settings: settings, peerType: .group, networkType: .wifi, media: nil, hardenedPolicy: .lockdown))
        XCTAssertTrue(shouldDownloadMediaAutomatically(settings: settings, peerType: .otherPrivate, networkType: .wifi, media: nil, hardenedPolicy: .inactive))
    }

    func testAutomaticDownloadFromAContactStillWorksUnderLockdown() {
        let settings = MediaAutoDownloadSettings.defaultSettings
        XCTAssertTrue(shouldDownloadMediaAutomatically(settings: settings, peerType: .contact, networkType: .wifi, media: nil, hardenedPolicy: .lockdown))
    }
}
