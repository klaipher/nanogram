import Foundation
import WatchKit

/// The three setTdlibParameters fields that describe the device and build (WATCH-I18N-1). They used to be fixed
/// (`"en"`, `"0.1"`, nil), so non-English accounts got English server-generated text (service messages, bot and
/// system strings) and the sessions list never showed the real build.
///
/// All three are server-visible, so they stay at the old values unless `WatchFeature.localizedTdlibParameters` is
/// on (the owner decides; it moves towards what the official clients send).
struct TdlibSystemInfo: Equatable {
    let languageCode: String
    let applicationVersion: String
    let systemVersion: String?

    /// What the watch app has always sent.
    static let legacy = TdlibSystemInfo(languageCode: "en", applicationVersion: "0.1", systemVersion: nil)

    /// Language code of the first preferred language (`"uk-UA"` gives `"uk"`); `"en"` when there is none.
    static func languageCode(preferredLanguages: [String]) -> String {
        guard let first = preferredLanguages.first,
              let code = Locale(identifier: first).language.languageCode?.identifier,
              !code.isEmpty, code != "und" else {
            return "en"
        }
        return code
    }

    static func make(
        preferredLanguages: [String],
        shortVersion: String?,
        systemVersion: String?
    ) -> TdlibSystemInfo {
        let version = (shortVersion?.isEmpty == false) ? shortVersion : nil
        let system = (systemVersion?.isEmpty == false) ? systemVersion : nil
        return TdlibSystemInfo(
            languageCode: languageCode(preferredLanguages: preferredLanguages),
            applicationVersion: version ?? legacy.applicationVersion,
            systemVersion: system
        )
    }

    /// The device's real values.
    @MainActor
    static func current(bundle: Bundle = .main) -> TdlibSystemInfo {
        make(
            preferredLanguages: Locale.preferredLanguages,
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            systemVersion: WKInterfaceDevice.current().systemVersion
        )
    }

    /// The parameters to send: the device's values when the flag is on, the old fixed ones otherwise.
    @MainActor
    static func resolve(enabled: Bool, bundle: Bundle = .main) -> TdlibSystemInfo {
        enabled ? current(bundle: bundle) : legacy
    }
}
