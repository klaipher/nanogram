import Foundation

/// Behaviour switches for the modernization specs that change what users see or hear, or that depend on
/// hardware we cannot check without a device (docs: `Telegram/WatchApp` section of NANOGRAM-CHANGES.md).
///
/// Every flag is OFF unless the owner turns it on, except the ones in `shippedOn` (the widget summary and its
/// background refresh, IOS-WATCH-WIDGET-1). A flag is a `UserDefaults` bool under
/// `nanogram.watch.<name>`, so a test run or a device scheme can flip it with a launch argument
/// (`-nanogram.watch.longFormAudio YES`) without a rebuild. Nothing here is server-visible by itself; the
/// flags that change a server-visible parameter say so on their case.
enum WatchFeature: String, CaseIterable, Sendable {
    /// WATCH-AUDIO-1 / IOS-WATCH-AUDIO-1: long-form route policy (Bluetooth headphones through the system
    /// route picker) and Now Playing / remote commands for music files. The audio background mode in
    /// Info.plist is static and only matters while a long-form session plays.
    case longFormAudio
    /// WATCH-MEM-1: voice notes decode in ~1 s chunks and start playing after the first, instead of decoding
    /// the whole note (up to ~115 MB for a 5-minute note) before any sound.
    case chunkedVoiceDecode
    /// WATCH-GPU-1: animated stickers rasterise off the main actor (late frames are dropped, not queued), and
    /// the timeline ticks at 24 Hz instead of 30 in Low Power Mode.
    case offMainStickerRender
    /// WATCH-LIST-1: the open chat keeps about 120 messages and drops the end the user is not reading.
    /// Needs a device check of scroll-position preservation (the list is a plain VStack).
    case messageWindowTrim
    /// WATCH-LIST-1: progress-only file updates (a video downloading) no longer rebuild every row.
    case fileProgressThrottle
    /// WATCH-I18N-1: setTdlibParameters sends the device's language, the app's version and the OS version instead
    /// of "en" / "0.1" / nil. SERVER-VISIBLE (service messages and bot text come back in that language; the
    /// sessions list shows the version), so it needs the owner's decision.
    case localizedTdlibParameters
    /// WATCH-VIDEO-1: an MP4 starts playing once its first 256 KB are on disk (served to AVPlayer from TDLib's
    /// growing file) instead of after the whole download. Round notes and videos; a clip with its index at the
    /// end waits for the full file as before. Needs a device check on LTE and Wi-Fi.
    case progressiveVideoStart
    /// IOS-WATCH-WIDGET-1: the app writes an unread summary (counts and chat titles) to the App Group for the widget
    /// extension. Does nothing until the App Group exists in the portal and in the app's entitlements.
    case widgetSnapshot
    /// WATCH-INT-1: the app wakes for system background refreshes (about every 30 minutes, within the system budget),
    /// lets TDLib catch up for a few seconds and refreshes the widget summary. Needs no portal capability.
    case backgroundRefresh
    /// WATCH-INT-1: the watch registers its own APNs token with TDLib (registerDevice), so messages can arrive with
    /// the phone away. SERVER-VISIBLE (a new device on the account) and needs the push entitlement and a
    /// notification service extension to be useful; see the owner steps.
    case pushRegistration

    var defaultsKey: String { "nanogram.watch." + rawValue }

    /// Flags that ship on. A launch argument or defaults value of NO still turns one off.
    static let shippedOn: Set<WatchFeature> = [.widgetSnapshot, .backgroundRefresh]

    /// Every other flag ships off; the owner enables them after checking on a device.
    var defaultValue: Bool { Self.shippedOn.contains(self) }
}

struct WatchFeatureFlags: @unchecked Sendable {
    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
    }

    static let standard = WatchFeatureFlags()

    func isEnabled(_ feature: WatchFeature) -> Bool {
        guard store.object(forKey: feature.defaultsKey) != nil else { return feature.defaultValue }
        return store.bool(forKey: feature.defaultsKey)
    }

    static func isEnabled(_ feature: WatchFeature) -> Bool {
        standard.isEnabled(feature)
    }
}
