import Foundation

/// `nanogram://` is Nanogram's own URL scheme (Telegram/BUILD registers it next to Telegram's `tg://` and
/// `telegram://`), so launchers such as one sec can open Nanogram even when official Telegram, which also claims
/// `tg://`, is installed.
public enum NanogramAppScheme {
    public static let scheme = "nanogram"

    public enum Action: Equatable {
        /// `nanogram://` with nothing after it: just bring the app to the front.
        case openApp
        /// Open this URL the usual way: `nanogram://x` becomes `tg://x`, any other URL is unchanged.
        case open(URL)
    }

    /// Never hands a `nanogram:` URL on: the app would pass an unknown scheme back to iOS, which opens Nanogram again.
    public static func action(for url: URL) -> Action {
        guard url.scheme?.lowercased() == scheme else {
            return .open(url)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .openApp
        }
        let host = components.host ?? ""
        let path = components.path
        let query = components.query ?? ""
        if host.isEmpty && (path.isEmpty || path == "/") && query.isEmpty {
            return .openApp
        }
        components.scheme = "tg"
        guard let telegramUrl = components.url else {
            return .openApp
        }
        return .open(telegramUrl)
    }
}
