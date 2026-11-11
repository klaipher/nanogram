import Foundation

/// Nanogram: the switches of this device for message widgets, apart from the server's kill switch
/// (`MessageWidgetKillSwitch`). Both live in `UserDefaults` and are read on any thread.
///
/// - Message widgets (Debug Settings): off by default since 2026-11-11 (the owner, after tg-widget-rce: a widget's script
///   runs on layout, with no tap, in the engine of Telegram 13.2 that a published exploit reaches); off, every widget
///   message shows the unsupported-content pill and no script runs. Turning them on also forgets the sources the crash
///   sentinel blocked. The key is new with that default, so an "on" stored before it (the old default was on) is not
///   read.
/// - Widget wallet (Debug Settings): off by default until the real path (prepare, the TON Connect window, the signature,
///   the bot's query) has been tested on a device with a funded test wallet (widgets finding W3). Off, widgets get no
///   `TelegramWidget.wallet` whatever the app configuration and the wallet say.
///
/// A flip posts `MessageWidgetAvailability`'s change, so open chats lay their widgets out again.
public enum MessageWidgetLocalSettings {
    public static let widgetsEnabledKey = "nanogram.messageWidgets.enabled.2"
    public static let walletEnabledKey = "nanogram.messageWidgets.walletEnabled"

    public static func widgetsEnabled(defaults: UserDefaults = .standard) -> Bool {
        return defaults.bool(forKey: self.widgetsEnabledKey)
    }

    public static func setWidgetsEnabled(_ enabled: Bool, defaults: UserDefaults = .standard, sentinel: MessageWidgetCrashSentinel = .shared) {
        let changed = self.widgetsEnabled(defaults: defaults) != enabled
        defaults.set(enabled, forKey: self.widgetsEnabledKey)
        if enabled {
            sentinel.clearBlocked()
        }
        if changed {
            MessageWidgetAvailability.noteChange()
        }
    }

    public static func walletEnabled(defaults: UserDefaults = .standard) -> Bool {
        return defaults.bool(forKey: self.walletEnabledKey)
    }

    public static func setWalletEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        let changed = self.walletEnabled(defaults: defaults) != enabled
        defaults.set(enabled, forKey: self.walletEnabledKey)
        if changed {
            MessageWidgetAvailability.noteChange()
        }
    }
}
