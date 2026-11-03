import XCTest
@testable import NanogramBranding

final class NanogramBrandingTests: XCTestCase {
    // How the language packs write the passcode screen's "Unlock Telegram" (EnterPasscode.TouchId).
    private let unlockFixtures: [(language: String, value: String, expected: String)] = [
        ("en", "Unlock Telegram", "Unlock Nanogram"),
        ("de", "Telegram entsperren", "Nanogram entsperren"),
        ("ru", "Разблокировать Telegram", "Разблокировать Nanogram"),
        ("uk", "Розблокувати Телеграм", "Розблокувати Nanogram"),
        ("ar", "فتح قفل تيليجرام", "فتح قفل Nanogram"),
        ("fa", "باز کردن قفل تلگرام", "باز کردن قفل Nanogram"),
        ("ko", "텔레그램 잠금 해제", "Nanogram 잠금 해제"),
        ("tr", "Telegram'ın kilidini aç", "Nanogram'ın kilidini aç"),
        ("pl", "Odblokuj Telegrama", "Odblokuj Nanograma"),
    ]

    func testIdentityValuesNameNanogramInEveryLanguage() {
        for fixture in self.unlockFixtures {
            let branded = nanogramBrandedStrings(["EnterPasscode.TouchId": fixture.value])
            XCTAssertEqual(branded["EnterPasscode.TouchId"], fixture.expected, fixture.language)
        }
    }

    func testDoubledCyrillicSpellingIsReplacedWhole() {
        let branded = nanogramBrandedStrings(["EnterPasscode.TouchId": "Разблокировать Телеграмм"])
        XCTAssertEqual(branded["EnterPasscode.TouchId"], "Разблокировать Nanogram")
    }

    // Strings about the network or its products are not about this app.
    func testOtherKeysAreUntouched() {
        let pack = [
            "Premium.Title": "Telegram Premium",
            "Notification.Joined": "%@ joined Telegram",
            "Settings.FAQ": "Telegram FAQ",
            "Notification.Joined_de": "%@ ist jetzt bei Telegram",
        ]
        XCTAssertEqual(nanogramBrandedStrings(pack), pack)
    }

    func testProtectedPhrasesSurviveInsideIdentityValues() {
        let value = "Telegram Premium, Telegram Stars and Telegram Passport stay; Telegram goes. See https://telegram.org/update or t.me/x"
        let branded = NanogramBranding.brand(["Key": value], identityKeys: ["Key"], rewriteOnlyKeys: [])
        XCTAssertEqual(branded["Key"], "Telegram Premium, Telegram Stars and Telegram Passport stay; Nanogram goes. See https://telegram.org/update or t.me/x")
    }

    // A protected phrase is a whole word: "Telegram Webinar" is not Telegram Web.
    func testProtectedPhraseEndsAtAWordBoundary() {
        let branded = NanogramBranding.brand(["Key": "Telegram Webinar, Telegram Web-Version"], identityKeys: ["Key"], rewriteOnlyKeys: [])
        XCTAssertEqual(branded["Key"], "Nanogram Webinar, Telegram Web-Version")
    }

    func testUnsupportedMediaKeepsTheUpdateLink() {
        let branded = nanogramBrandedStrings(["Conversation.UnsupportedMedia": "This message is not supported on your version of Telegram. Update the app to view:\nhttps://telegram.org/update"])
        XCTAssertEqual(branded["Conversation.UnsupportedMedia"], "This message is not supported on your version of Nanogram. Update the app to view:\nhttps://telegram.org/update")
    }

    func testPluralFormsOfAnIdentityKeyAreBranded() {
        let pack = [
            "Key_0": "Telegram 0",
            "Key_1": "Telegram 1",
            "Key_2": "Telegram 2",
            "Key_3_10": "Telegram few",
            "Key_many": "Telegram many",
            "Key_any": "Telegram any",
            "Key_zero": "Telegram zero",
            "KeyOther_1": "Telegram",
            "Key.Other": "Telegram",
        ]
        let branded = NanogramBranding.brand(pack, identityKeys: ["Key"], rewriteOnlyKeys: [])
        for suffix in ["_0", "_1", "_2", "_3_10", "_many", "_any", "_zero"] {
            XCTAssertFalse(branded["Key" + suffix]!.contains("Telegram"), suffix)
            XCTAssertTrue(branded["Key" + suffix]!.hasPrefix("Nanogram"), suffix)
        }
        XCTAssertEqual(branded["KeyOther_1"], "Telegram")
        XCTAssertEqual(branded["Key.Other"], "Telegram")
    }

    // The desktop links now lead to Nanogram's releases, in every language.
    func testDesktopDownloadTextPointsToNanogramReleases() {
        let branded = nanogramBrandedStrings([
            "AuthSessions.AddDeviceIntro.Text1": "Lade Telegram von [desktop.telegram.org]() auf deinen Computer herunter",
            "AuthSessions.AddDevice.ScanInstallInfo": "Gehe zu [getdesktop.telegram.org](desktop) oder [web.telegram.org](web), um den QR-Code zu erhalten",
            "AuthSessions.HeaderInfo": "Verknüpfe [Telegram Desktop](desktop) oder [Telegram Web](web), indem du einen QR-Code scannst.",
        ])
        XCTAssertEqual(branded["AuthSessions.AddDeviceIntro.Text1"], "Lade Nanogram von [github.com/klaipher/nanogram-releases]() auf deinen Computer herunter")
        XCTAssertEqual(branded["AuthSessions.AddDevice.ScanInstallInfo"], "Gehe zu [github.com/klaipher/nanogram-releases](desktop) oder [web.telegram.org](web), um den QR-Code zu erhalten")
        XCTAssertEqual(branded["AuthSessions.HeaderInfo"], "Verknüpfe [Nanogram Desktop](desktop) oder [Telegram Web](web), indem du einen QR-Code scannst.")
    }

    // A rewrite-only key keeps every other "Telegram": there it names Telegram's own products.
    func testRewriteOnlyKeysKeepTheirTokens() {
        let branded = NanogramBranding.brand(["Key": "Telegram Desktop or Telegram for Web"], identityKeys: [], rewriteOnlyKeys: ["Key"])
        XCTAssertEqual(branded["Key"], "Nanogram Desktop or Telegram for Web")
    }

    func testBrandingIsIdempotent() {
        var pack: [String: String] = [:]
        for key in NanogramIdentityKeys.identityKeys {
            pack[key] = "Telegram app [desktop.telegram.org]() Telegram Premium"
        }
        for key in NanogramIdentityKeys.rewriteOnlyKeys {
            pack[key] = "[Telegram Desktop](desktop) [getdesktop.telegram.org](desktop)"
        }
        let once = nanogramBrandedStrings(pack)
        XCTAssertEqual(nanogramBrandedStrings(once), once)
        for key in NanogramIdentityKeys.identityKeys {
            XCTAssertEqual(once[key], "Nanogram app [github.com/klaipher/nanogram-releases]() Telegram Premium", key)
        }
    }

    func testKeyListsAreDisjointAndCoverTheAppIdentity() {
        let identity = Set(NanogramIdentityKeys.identityKeys)
        let rewriteOnly = Set(NanogramIdentityKeys.rewriteOnlyKeys)
        XCTAssertEqual(identity.count, NanogramIdentityKeys.identityKeys.count, "duplicate identity key")
        XCTAssertEqual(rewriteOnly.count, NanogramIdentityKeys.rewriteOnlyKeys.count, "duplicate rewrite-only key")
        XCTAssertTrue(identity.isDisjoint(with: rewriteOnly))
        for key in ["Tour.Text2", "EnterPasscode.TouchId", "Share.AuthTitle", "Watch.AuthRequired", "AccessDenied.Camera"] {
            XCTAssertTrue(identity.contains(key), key)
        }
        // Network products and the network's own strings stay Telegram's.
        for key in ["Premium.Title", "Notification.Joined", "Settings.FAQ", "Settings.Passport"] {
            XCTAssertFalse(identity.contains(key), key)
        }
    }
}
