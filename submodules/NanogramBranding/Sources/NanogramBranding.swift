/// Applies `NanogramBranding` to a language pack's key-value table.
///
/// The strings come from the bundled English table or from a language pack downloaded from
/// Telegram's servers, which say "Telegram" where they mean the app. This rewrites only the
/// values of `NanogramIdentityKeys`, so it runs once per language load and every other string
/// is passed through unchanged.
public func nanogramBrandedStrings(_ strings: [String: String]) -> [String: String] {
    return NanogramBranding.brand(strings, identityKeys: NanogramIdentityKeys.identityKeys, rewriteOnlyKeys: NanogramIdentityKeys.rewriteOnlyKeys)
}

public enum NanogramBranding {
    public static let appName = "Nanogram"

    /// Telegram's desktop app is Nanogram's here; its downloads are Nanogram's releases.
    static let releasesAddress = "github.com/klaipher/nanogram-releases"
    static let rewrites: [(String, String)] = [
        ("getdesktop.telegram.org", releasesAddress),
        ("desktop.telegram.org", releasesAddress),
        ("Telegram Desktop", "\(appName) Desktop"),
    ]

    /// Names of the network and its products, left as they are inside an identity value.
    static let protectedPhrases: [String] = [
        "Telegram Premium",
        "Telegram Stars",
        "Telegram Passport",
        "Telegram Business",
        "Telegram Gifts",
        "Telegram Ads",
        "Telegram Web",
        "Telegram FAQ",
        "Telegram Support",
        "Telegram account",
        "Telegram cloud",
        "Telegram servers",
        "Telegram.org",
    ]

    /// How the language packs spell Telegram: Latin, Cyrillic, Arabic, Persian, Korean, Hebrew.
    /// Longer spellings come first, so a doubled ending is replaced whole.
    static let tokens: [String] = [
        "Telegram",
        "Телеграмм",
        "Телеграм",
        "تيليجرام",
        "تيلجرام",
        "تليجرام",
        "تلگرام",
        "텔레그램",
        "טלגרם",
    ]

    /// The plural forms `dictFromLocalization` and the bundled tables use (`Key_1`, `Key_any`, ...).
    static let pluralSuffixes: [String] = ["", "_0", "_zero", "_1", "_2", "_3_10", "_many", "_any"]

    static func brand(_ strings: [String: String], identityKeys: [String], rewriteOnlyKeys: [String]) -> [String: String] {
        var result = strings
        for (keys, replacingTokens) in [(identityKeys, true), (rewriteOnlyKeys, false)] {
            for key in keys {
                for suffix in pluralSuffixes {
                    let fullKey = key + suffix
                    if let value = result[fullKey] {
                        result[fullKey] = brandedValue(value, replacingTokens: replacingTokens)
                    }
                }
            }
        }
        return result
    }

    /// One pass from the start: at each position the first matching rule wins (a rewrite, then a
    /// protected phrase, which is kept, then a spelling of Telegram), so a protected phrase is
    /// never split by a token inside it.
    static func brandedValue(_ value: String, replacingTokens: Bool) -> String {
        // (match, replacement, whole word only)
        var rules: [(String, String, Bool)] = rewrites.map { ($0.0, $0.1, false) }
        if replacingTokens {
            rules += protectedPhrases.map { ($0, $0, true) }
            rules += tokens.map { ($0, appName, false) }
        }
        var result = ""
        var rest = value[...]
        scan: while !rest.isEmpty {
            for (match, replacement, wholeWord) in rules where rest.hasPrefix(match) {
                let after = rest.dropFirst(match.count)
                if wholeWord, let next = after.first, next.isLetter {
                    continue
                }
                result += replacement
                rest = after
                continue scan
            }
            result.append(rest.removeFirst())
        }
        return result
    }
}
